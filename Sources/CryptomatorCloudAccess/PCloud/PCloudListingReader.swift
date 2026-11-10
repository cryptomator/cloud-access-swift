//
//  PCloudListingReader.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 09.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Reads a response of `listfolder` from a file in chunks, so that a folder of any size is never held in memory.

 It checks what `JSONDecoder` checks of a whole UTF-8 body before it decodes a member: an object at the root followed only by whitespace, at most one leading byte order mark, trailing commas before `}` or `]`, the literals, and strings and numbers only as far as needed to find their ends.

 Like `JSONDecoder`, it leaves the content of a string and the spelling of a number to where they are decoded. It decodes the keys at the root and in `metadata` itself, and its callers decode the members it captures (the result, the error, the folder's fields and each child). Of the members it reads that occur more than once in an object, the first one counts, as in `JSONDecoder`.

 Anything it doesn't accept, a truncated file included, throws `PCloudError.unexpectedContent`.

 A key at the root or in `metadata` over 4 KiB, a `result` over 4 KiB, an element of `contents` over 64 KiB, the read fields of `metadata` over 64 KiB together, or nesting deeper than 64 levels throws `PCloudError.listingTooLarge`.
 */
enum PCloudListingReader {
	/// What a listing holds in the members that a client judges. The reader records them without throwing, so that the client can treat each of them as a whole-body decode would.
	struct Summary: Equatable {
		// swiftlint:disable:next nesting
		enum Result: Equatable {
			case absent
			/// The number's bytes, which `JSONDecoder` reads.
			case number(Data)
			case other
		}

		// swiftlint:disable:next nesting
		enum Message: Equatable {
			case absent
			case null
			/// The string's bytes with their quotes and escapes, if there are at most 4 KiB of them.
			case string(Data)
			case oversizedString
			case other
		}

		// swiftlint:disable:next nesting
		enum Metadata: Equatable {
			case absent
			case null
			case object
			/// Any other value, or an object with a key that `JSONDecoder` can't decode.
			case other
		}

		// swiftlint:disable:next nesting
		enum Contents: Equatable {
			case absent
			case null
			/// An array whose elements are all objects.
			case objects
			case other
		}

		var result = Result.absent
		var error = Message.absent
		var metadata = Metadata.absent
		var contents = Contents.absent
		/// The members of `metadata` that `PCloudMetadata` reads, as `"key":value` separated by commas.
		var folderFields = Data()
	}

	/// Reads the whole file.
	static func validate(fileAt url: URL, chunkSize: Int = HTTPClientSupport.temporaryFileBufferLength) throws -> Summary {
		var scanner = ListingScanner(storesChildren: false)
		try scan(fileAt: url, chunkSize: chunkSize, with: &scanner) { _ in true }
		return scanner.summary
	}

	/// Passes the bytes of each element of `contents`, in order, to `body` until it returns false. It doesn't judge the kinds of members, so the file must be one that `validate(fileAt:)` accepted.
	static func forEachChild(inFileAt url: URL, chunkSize: Int = HTTPClientSupport.temporaryFileBufferLength, _ body: (Data) throws -> Bool) throws {
		var scanner = ListingScanner(storesChildren: true)
		try scan(fileAt: url, chunkSize: chunkSize, with: &scanner, onChild: body)
	}

	private static func scan(fileAt url: URL, chunkSize: Int, with scanner: inout ListingScanner, onChild: (Data) throws -> Bool) throws {
		let fileHandle = try FileHandle(forReadingFrom: url)
		defer {
			try? fileHandle.close()
		}
		while true {
			let isFinished = try autoreleasepool {
				guard let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
					try scanner.finish()
					return true
				}
				return try scanner.feed(chunk, onChild: onChild)
			}
			if isFinished {
				return
			}
		}
	}
}

// MARK: - Scanner

private struct ListingScanner {
	private enum Role {
		case root
		case metadata
		case contents
		case other
	}

	/// A member at the root or in `metadata` that the scanner records.
	private enum Member {
		case result
		case error
		case metadata
		case contents
		case field(String)
	}

	private enum Expectation {
		case keyOrEnd
		case colon
		case value
		case valueOrEnd
		case commaOrEnd
	}

	private struct Frame {
		let isObject: Bool
		let role: Role
		var expectation: Expectation
		/// The member whose value comes next, if the scanner records it.
		var member: Member?
	}

	private enum Token {
		case none
		case key
		case string
		case number
		case literal
	}

	private enum Escape {
		case none
		case backslash
		/// In the hex digits of a `\u` escape, of which `remaining` follow.
		case unicode(remaining: Int)
	}

	private enum Capture {
		case none
		case result
		case error
		case field
		case child
	}

	private static let maxKeyLength = 4 * 1024
	private static let maxResultLength = 4 * 1024
	private static let maxElementLength = 64 * 1024
	private static let maxFolderFieldsLength = 64 * 1024
	private static let maxDepth = 64
	private static let maxErrorLength = 4 * 1024
	private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
	private static let trueLiteral = Array("true".utf8)
	private static let falseLiteral = Array("false".utf8)
	private static let nullLiteral = Array("null".utf8)
	private static let fieldNames: Set<String> = ["isfolder", "name", "folderid", "fileid", "modified", "size"]

	private(set) var summary = PCloudListingReader.Summary()
	private let storesChildren: Bool

	private var isAtStart = true
	private var byteOrderMarkLength = 0
	private var stack = [Frame]()
	private var isRootClosed = false
	private var rootMembers = Set<String>()
	private var metadataMembers = Set<String>()

	private var token = Token.none
	private var literal = [UInt8]()
	private var literalIndex = 0
	private var escape = Escape.none

	private var isCapturingKey = false
	private var keyBytes = [UInt8]()

	private var capture = Capture.none
	/// The depth of a captured container, or -1 for a captured scalar.
	private var captureDepth = -1
	private var captured = [UInt8]()
	private var capturedLength = 0
	private var isCaptureOverflowed = false
	private var folderFields = [UInt8]()
	private var completedChild: Data?

	init(storesChildren: Bool) {
		self.storesChildren = storesChildren
	}

	/// - Returns: Whether `onChild` stopped the scan.
	mutating func feed(_ chunk: Data, onChild: (Data) throws -> Bool) throws -> Bool {
		return try chunk.withUnsafeBytes { buffer in
			for byte in buffer {
				try step(byte)
				if let child = completedChild {
					completedChild = nil
					if try !onChild(child) {
						return true
					}
				}
			}
			return false
		}
	}

	mutating func finish() throws {
		guard isRootClosed else {
			throw PCloudError.unexpectedContent
		}
		summary.folderFields = Data(folderFields)
	}

	// MARK: - Grammar

	private mutating func step(_ byte: UInt8) throws {
		if isAtStart, try byteOrderMarkStep(byte) {
			return
		}
		switch token {
		case .key, .string:
			try stringStep(byte)
		case .number:
			try numberStep(byte)
		case .literal:
			try literalStep(byte)
		case .none:
			try structuralStep(byte)
		}
	}

	/// - Returns: Whether the byte belongs to the byte order mark.
	private mutating func byteOrderMarkStep(_ byte: UInt8) throws -> Bool {
		if byte == ListingScanner.byteOrderMark[byteOrderMarkLength] {
			byteOrderMarkLength += 1
			isAtStart = byteOrderMarkLength < ListingScanner.byteOrderMark.count
			return true
		}
		guard byteOrderMarkLength == 0 else {
			throw PCloudError.unexpectedContent
		}
		isAtStart = false
		return false
	}

	/// Reads a number as `JSONDecoder` does before decoding it: as a run of digits, `.`, `+`, `-`, `e` and `E`.
	private mutating func numberStep(_ byte: UInt8) throws {
		switch byte {
		case UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "e"), UInt8(ascii: "E"):
			try append(byte)
		default:
			token = .none
			scalarEnded()
			try structuralStep(byte)
		}
	}

	private mutating func literalStep(_ byte: UInt8) throws {
		guard byte == literal[literalIndex] else {
			throw PCloudError.unexpectedContent
		}
		try append(byte)
		literalIndex += 1
		if literalIndex == literal.count {
			token = .none
			scalarEnded()
		}
	}

	private mutating func structuralStep(_ byte: UInt8) throws {
		if ListingScanner.isWhitespace(byte) {
			try append(byte)
			return
		}
		guard !isRootClosed else {
			throw PCloudError.unexpectedContent
		}
		guard let top = stack.indices.last else {
			try openRoot(with: byte)
			return
		}
		switch stack[top].expectation {
		case .keyOrEnd:
			try keyOrEndStep(byte)
		case .colon:
			try colonStep(byte, top: top)
		case .value:
			try startValue(byte)
		case .valueOrEnd:
			try valueOrEndStep(byte)
		case .commaOrEnd:
			try commaOrEndStep(byte, top: top)
		}
	}

	private mutating func openRoot(with byte: UInt8) throws {
		guard byte == UInt8(ascii: "{") else {
			throw PCloudError.unexpectedContent
		}
		try push(isObject: true, role: .root)
	}

	private mutating func keyOrEndStep(_ byte: UInt8) throws {
		if byte == UInt8(ascii: "\"") {
			try append(byte)
			startString(isKey: true)
		} else if byte == UInt8(ascii: "}") {
			try append(byte)
			closeContainer()
		} else {
			throw PCloudError.unexpectedContent
		}
	}

	private mutating func colonStep(_ byte: UInt8, top: Int) throws {
		guard byte == UInt8(ascii: ":") else {
			throw PCloudError.unexpectedContent
		}
		try append(byte)
		stack[top].expectation = .value
	}

	private mutating func valueOrEndStep(_ byte: UInt8) throws {
		if byte == UInt8(ascii: "]") {
			try append(byte)
			closeContainer()
		} else {
			try startValue(byte)
		}
	}

	private mutating func commaOrEndStep(_ byte: UInt8, top: Int) throws {
		if byte == UInt8(ascii: ",") {
			try append(byte)
			stack[top].expectation = stack[top].isObject ? .keyOrEnd : .valueOrEnd
		} else if byte == UInt8(ascii: stack[top].isObject ? "}" : "]") {
			try append(byte)
			closeContainer()
		} else {
			throw PCloudError.unexpectedContent
		}
	}

	private mutating func startValue(_ byte: UInt8) throws {
		let (role, newCapture) = try recordStart(of: byte, in: stack[stack.count - 1])
		if newCapture != .none {
			capture = newCapture
			captured.removeAll(keepingCapacity: true)
			capturedLength = 0
			isCaptureOverflowed = false
			captureDepth = -1
		}
		try append(byte)
		try startToken(byte, role: role, isCaptured: newCapture != .none)
	}

	/// Records the kind of a recorded member's value from its first byte, and returns the role of the container that the value opens and what to capture of it.
	private mutating func recordStart(of byte: UInt8, in parent: Frame) throws -> (Role, Capture) {
		switch (parent.role, parent.member) {
		case (.root, .result?):
			guard byte == UInt8(ascii: "-") || ListingScanner.isDigit(byte) else {
				summary.result = .other
				return (.other, .none)
			}
			return (.other, .result)
		case (.root, .error?):
			return (.other, recordErrorStart(byte))
		case (.root, .metadata?):
			summary.metadata = ListingScanner.metadataKind(startingWith: byte)
			return (summary.metadata == .object ? .metadata : .other, .none)
		case (.metadata, .contents?):
			summary.contents = ListingScanner.contentsKind(startingWith: byte)
			return (summary.contents == .objects ? .contents : .other, .none)
		case let (.metadata, .field(name)?):
			try appendFolderFields((folderFields.isEmpty ? "" : ",") + "\"\(name)\":")
			return (.other, .field)
		case (.contents, _):
			guard byte == UInt8(ascii: "{") else {
				summary.contents = .other
				return (.other, .none)
			}
			return (.other, .child)
		default:
			return (.other, .none)
		}
	}

	private mutating func recordErrorStart(_ byte: UInt8) -> Capture {
		switch byte {
		case UInt8(ascii: "\""):
			return .error
		case UInt8(ascii: "n"):
			summary.error = .null
		default:
			summary.error = .other
		}
		return .none
	}

	private mutating func startToken(_ byte: UInt8, role: Role, isCaptured: Bool) throws {
		switch byte {
		case UInt8(ascii: "{"), UInt8(ascii: "["):
			try push(isObject: byte == UInt8(ascii: "{"), role: role)
			if isCaptured {
				captureDepth = stack.count
			}
		case UInt8(ascii: "\""):
			startString(isKey: false)
		case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
			token = .number
		case UInt8(ascii: "t"):
			startLiteral(ListingScanner.trueLiteral)
		case UInt8(ascii: "f"):
			startLiteral(ListingScanner.falseLiteral)
		case UInt8(ascii: "n"):
			startLiteral(ListingScanner.nullLiteral)
		default:
			throw PCloudError.unexpectedContent
		}
	}

	private mutating func push(isObject: Bool, role: Role) throws {
		guard stack.count < ListingScanner.maxDepth else {
			throw PCloudError.listingTooLarge
		}
		stack.append(Frame(isObject: isObject, role: role, expectation: isObject ? .keyOrEnd : .valueOrEnd))
	}

	private mutating func startLiteral(_ literal: [UInt8]) {
		token = .literal
		self.literal = literal
		literalIndex = 1
	}

	private mutating func startString(isKey: Bool) {
		token = isKey ? .key : .string
		escape = .none
		if isKey, let role = stack.last?.role, role == .root || role == .metadata {
			isCapturingKey = true
			keyBytes = [UInt8(ascii: "\"")]
		}
	}

	private mutating func closeContainer() {
		let depth = stack.count
		stack.removeLast()
		if capture != .none, captureDepth == depth {
			finishCapture()
		}
		if stack.isEmpty {
			isRootClosed = true
		} else {
			valueEnded()
		}
	}

	private mutating func scalarEnded() {
		if capture != .none, captureDepth == -1 {
			finishCapture()
		}
		valueEnded()
	}

	private mutating func valueEnded() {
		stack[stack.count - 1].expectation = .commaOrEnd
		stack[stack.count - 1].member = nil
	}

	/// Matches a key at the root or in `metadata`, which `JSONDecoder` decodes along with the object. An invalid key at the root fails the listing at once, as `JSONDecoder` fails the result, while one in `metadata` fails only the metadata.
	private mutating func keyEnded() throws {
		let top = stack.count - 1
		stack[top].expectation = .colon
		guard isCapturingKey else {
			return
		}
		isCapturingKey = false
		let name = ListingScanner.decodedKey(keyBytes)
		switch stack[top].role {
		case .root:
			guard let name else {
				throw PCloudError.unexpectedContent
			}
			if let member = ListingScanner.rootMember(named: name), rootMembers.insert(name).inserted {
				stack[top].member = member
			}
		case .metadata:
			guard let name else {
				summary.metadata = .other
				return
			}
			if let member = ListingScanner.metadataMember(named: name), metadataMembers.insert(name).inserted {
				stack[top].member = member
			}
		case .contents, .other:
			break
		}
	}

	// MARK: - Strings

	/// Reads a string as `JSONDecoder` does before decoding it: up to the next quote that no backslash escapes, where a `\u` escape spans the 4 bytes after it, none of which may be a quote.
	private mutating func stringStep(_ byte: UInt8) throws {
		try append(byte)
		switch escape {
		case .backslash:
			escape = byte == UInt8(ascii: "u") ? .unicode(remaining: 4) : .none
		case let .unicode(remaining):
			guard byte != UInt8(ascii: "\"") else {
				throw PCloudError.unexpectedContent
			}
			escape = remaining > 1 ? .unicode(remaining: remaining - 1) : .none
		case .none:
			if byte == UInt8(ascii: "\"") {
				let isKey = token == .key
				token = .none
				if isKey {
					try keyEnded()
				} else {
					scalarEnded()
				}
			} else if byte == UInt8(ascii: "\\") {
				escape = .backslash
			}
		}
	}

	// MARK: - Capturing

	private mutating func append(_ byte: UInt8) throws {
		if isCapturingKey {
			try appendKey(byte)
		}
		switch capture {
		case .none:
			break
		case .result:
			guard captured.count < ListingScanner.maxResultLength else {
				throw PCloudError.listingTooLarge
			}
			captured.append(byte)
		case .error:
			appendError(byte)
		case .field:
			guard folderFields.count < ListingScanner.maxFolderFieldsLength else {
				throw PCloudError.listingTooLarge
			}
			folderFields.append(byte)
		case .child:
			guard capturedLength < ListingScanner.maxElementLength else {
				throw PCloudError.listingTooLarge
			}
			capturedLength += 1
			if storesChildren {
				captured.append(byte)
			}
		}
	}

	private mutating func appendKey(_ byte: UInt8) throws {
		guard keyBytes.count < ListingScanner.maxKeyLength else {
			throw PCloudError.listingTooLarge
		}
		keyBytes.append(byte)
	}

	/// Keeps the bytes of the error message up to its limit, and only notes that a longer one overflowed.
	private mutating func appendError(_ byte: UInt8) {
		guard !isCaptureOverflowed else {
			return
		}
		if captured.count < ListingScanner.maxErrorLength {
			captured.append(byte)
		} else {
			isCaptureOverflowed = true
			captured.removeAll()
		}
	}

	private mutating func appendFolderFields(_ string: String) throws {
		folderFields.append(contentsOf: string.utf8)
		guard folderFields.count <= ListingScanner.maxFolderFieldsLength else {
			throw PCloudError.listingTooLarge
		}
	}

	private mutating func finishCapture() {
		switch capture {
		case .none, .field:
			break
		case .result:
			summary.result = .number(Data(captured))
		case .error:
			summary.error = isCaptureOverflowed ? .oversizedString : .string(Data(captured))
		case .child:
			if storesChildren {
				completedChild = Data(captured)
			}
		}
		capture = .none
	}

	// MARK: - Members

	private static func rootMember(named name: String) -> Member? {
		switch name {
		case "result": .result
		case "error": .error
		case "metadata": .metadata
		default: nil
		}
	}

	private static func metadataMember(named name: String) -> Member? {
		if name == "contents" {
			return .contents
		}
		return fieldNames.contains(name) ? .field(name) : nil
	}

	private static func metadataKind(startingWith byte: UInt8) -> PCloudListingReader.Summary.Metadata {
		switch byte {
		case UInt8(ascii: "{"): .object
		case UInt8(ascii: "n"): .null
		default: .other
		}
	}

	private static func contentsKind(startingWith byte: UInt8) -> PCloudListingReader.Summary.Contents {
		switch byte {
		case UInt8(ascii: "["): .objects
		case UInt8(ascii: "n"): .null
		default: .other
		}
	}

	// MARK: - Bytes

	private static func isDigit(_ byte: UInt8) -> Bool {
		return byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
	}

	private static func isWhitespace(_ byte: UInt8) -> Bool {
		return byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
	}

	/// Decodes a key with its quotes, so that an escaped key matches too, or returns `nil` if `JSONDecoder` can't decode it.
	private static func decodedKey(_ bytes: [UInt8]) -> String? {
		return try? JSONDecoder().decode([String].self, from: Data([UInt8(ascii: "[")] + bytes + [UInt8(ascii: "]")]))[0]
	}
}
