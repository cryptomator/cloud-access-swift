//
//  WebDAVXMLGuard.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// A construct of a WebDAV XML body that `WebDAVXMLGuard` refuses.
enum WebDAVXMLConstruct: Equatable {
	case tag
	case attributes
	case comment
	case cdata
	case processingInstruction
	case reference
	case names
	/// A document type declaration, any other `<!` markup than a comment or a CDATA section, or a CDATA section before the root element.
	case doctype
	/// A quote in an end tag or a `<` in an attribute value, either of which lets libxml2's wait for the end of a tag outlast the tag cap.
	case tagDelimiter
	case encoding
}

/// Names the refused construct and the cap it exceeds, never the body's content.
enum WebDAVXMLGuardError: Error, Equatable, CustomStringConvertible {
	case limitExceeded(WebDAVXMLConstruct)
	case unsupported(WebDAVXMLConstruct)

	var description: String {
		switch self {
		case let .limitExceeded(construct):
			return "\(construct) over its cap (\(WebDAVXMLGuardError.capDescription(of: construct)))"
		case let .unsupported(construct):
			return "unsupported \(construct)"
		}
	}

	private static func capDescription(of construct: WebDAVXMLConstruct) -> String {
		switch construct {
		case .tag:
			return "\(WebDAVXMLLimits.maxTagLength) bytes"
		case .attributes:
			return "\(WebDAVXMLLimits.maxAttributeCount) attributes"
		case .comment, .cdata, .processingInstruction:
			return "\(WebDAVXMLLimits.maxDelimitedLength) bytes of content"
		case .reference:
			return "\(WebDAVXMLLimits.maxReferenceLength) bytes"
		case .names:
			return "\(WebDAVXMLLimits.maxDistinctNames) distinct names or \(WebDAVXMLLimits.maxDistinctNameLength) bytes of them"
		case .doctype, .tagDelimiter, .encoding:
			return "none"
		}
	}
}

/**
 Scans a WebDAV XML body before `XMLParser` reads it, because libxml2 buffers some constructs whole before it calls a delegate and keeps every distinct name for the whole parse, which no delegate can bound.

 A start or end tag over 16 KiB, a start tag with over 64 attributes (`xmlns` declarations included), a comment, CDATA section or processing instruction (the XML declaration included) whose content exceeds 64 KiB, an entity or character reference in element content over 1 KiB, or more than 4,096 distinct names or 256 KiB of them (element and attribute qualified names, `xmlns` values and processing instruction targets) throws `limitExceeded` (`WebDAVXMLLimits`). Everything that libxml2 buffers before a callback or keeps for the whole parse must be bounded by one of these caps or by the delegates' depth cap, so a construct that libxml2 is found to buffer or keep whole must be added here before it is trusted. That includes what libxml2's push parser holds while it waits for more input. It waits for the `;` of a reference anywhere ahead, so a reference counts up to its `;`. It also waits for a tag's `>`, which it finds by a quote-aware scan from the last `<` in its buffer, so the guard tracks quotes in start tags the same way.

 A document type declaration or any other `<!` markup than a comment or a CDATA section throws `unsupported(.doctype)`. So does a CDATA section before the root element, because libxml2 reads only a processing instruction, a comment or a document type declaration as such there, and any other `<` as a start tag. An `oasis-xml-catalog` processing instruction before the root element throws `unsupported(.processingInstruction)`, because libxml2 keeps the catalog that it names for the whole parse. A quote in an end tag or a `<` in an attribute value, which the scan for a tag's `>` would read differently from the guard and which libxml2 rejects only once that scan ends, throws `unsupported(.tagDelimiter)`.

 A body that libxml2 detects as UTF-16, UTF-32, UCS-4 or EBCDIC by its first bytes throws `unsupported(.encoding)`, because a byte below 0x80 needn't be ASCII there. So does a body that declares an encoding other than UTF-8 or US-ASCII and their aliases, because libxml2 decodes it with a converter that can turn one byte into several. Such a converter can fall behind libxml2's check for a complete tag and let it buffer the following text whole. The guard reads only bytes below 0x80, as ASCII, and leaves whether the body is well-formed to libxml2.

 Known limits: it refuses bodies in ISO-8859-x, windows-125x, UTF-16 and every other encoding, which only a transcoding to UTF-8 before parsing could accept. It also refuses aliases of UTF-8 and US-ASCII outside the `iconv -l` alias groups (e.g. `windows-65001`, `windows-20127`) and encoding names that libxml2 resolves loosely (e.g. `UTF-8--`). A UTF-32 body that libxml2 doesn't detect (e.g. one that starts with whitespace) passes, and libxml2 then rejects it on its NUL bytes.
 */
struct WebDAVXMLGuard {
	private enum State: Equatable {
		case content
		case reference
		/// After `<`.
		case tagOpen
		case startTag
		case endTag
		/// After `<!`.
		case markup
		/// After `<!-`.
		case commentOpen
		/// After `<![` and the first `matched` bytes of `CDATA[`.
		case cdataOpen(matched: Int)
		case comment
		case cdata
		case processingInstruction
	}

	/// A name that is fingerprinted as it arrives, so that it is never buffered. It notes how many of its first bytes match `literal`, so that a name can be recognized without keeping it.
	private struct Name {
		static let namespacePrefix = Array("xmlns:".utf8)
		static let catalogTarget = Array("oasis-xml-catalog".utf8)

		private let literal: [UInt8]
		private var hasher = Hasher()
		private(set) var length = 0
		private var matchedPrefixLength = 0

		init(isNamespaceURI: Bool, literal: [UInt8]) {
			self.literal = literal
			hasher.combine(isNamespaceURI)
		}

		/// Whether the name is `literal`.
		var isLiteral: Bool {
			return matchedPrefixLength == length && length == literal.count
		}

		/// Whether an attribute name, matched against `namespacePrefix`, declares a namespace: `xmlns` or `xmlns:…`.
		var declaresNamespace: Bool {
			return matchedPrefixLength == literal.count || (matchedPrefixLength == length && length == literal.count - 1)
		}

		var fingerprint: Int {
			return hasher.finalize()
		}

		mutating func append(_ byte: UInt8) {
			hasher.combine(byte)
			if matchedPrefixLength == length, length < literal.count, byte == literal[length] {
				matchedPrefixLength += 1
			}
			length += 1
		}
	}

	private static let refusedSignatures: [[UInt8]] = [
		[0x00, 0x00, 0xFE, 0xFF], [0xFF, 0xFE, 0x00, 0x00],
		[0x00, 0x00, 0x00, 0x3C], [0x3C, 0x00, 0x00, 0x00], [0x00, 0x00, 0x3C, 0x00], [0x00, 0x3C, 0x00, 0x00],
		[0x4C, 0x6F, 0xA7, 0x94]
	]
	private static let cdataKeyword = Array("CDATA[".utf8)
	/// The first bytes of UTF-16 with or without a byte order mark.
	private static let utf16Signatures: [[UInt8]] = [[0x3C, 0x00, 0x3F, 0x00], [0x00, 0x3C, 0x00, 0x3F], [0xFE, 0xFF], [0xFF, 0xFE]]
	private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
	/// The aliases of UTF-8 and US-ASCII that `iconv -l` lists.
	private static let encodingNames: Set<String> = [
		"utf-8", "utf8", "us-ascii", "ascii", "us", "646", "ansi_x3.4-1968", "ansi_x3.4-1986", "iso646-us", "iso_646.irv:1991", "iso-ir-6", "cp367", "ibm367", "csascii"
	]

	private var isEncodingDecided = false
	private var detectionBytes = [UInt8]()
	private var byteIndex = 0

	private var state = State.content
	/// How many bytes of the current tag, reference, comment, CDATA section or processing instruction count against its cap so far.
	private var length = 0
	private var attributeCount = 0
	private var quote: UInt8?
	private var closerRunLength = 0
	private var isInProlog = true

	private var name: Name?
	private var isNamespaceDeclarationPending = false
	private var fingerprints = Set<Int>()
	private var distinctNameLength = 0

	/// The bytes of a processing instruction that starts the body, while it is open.
	private var declaration: [UInt8]?

	/**
	 Scans `data` whole.

	 Doesn't check for cancellation, so that a caller can still read a body that answers a completed remote change.
	 */
	static func validate(_ data: Data) throws {
		var markupGuard = WebDAVXMLGuard()
		try markupGuard.feed(data)
		try markupGuard.finish()
	}

	/// Scans the file at `url` whole, in reads of `chunkSize` bytes.
	static func validate(fileAt url: URL, chunkSize: Int = HTTPClientSupport.temporaryFileBufferLength) throws {
		let fileHandle = try FileHandle(forReadingFrom: url)
		defer {
			try? fileHandle.close()
		}
		var markupGuard = WebDAVXMLGuard()
		while true {
			try Task.checkCancellation()
			let isFinished = try autoreleasepool {
				guard let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
					try markupGuard.finish()
					return true
				}
				try markupGuard.feed(chunk)
				return false
			}
			if isFinished {
				return
			}
		}
	}

	mutating func feed(_ chunk: Data) throws {
		try chunk.withUnsafeBytes { buffer in
			for byte in buffer {
				try take(byte)
			}
		}
	}

	/// Leaves an unfinished construct to libxml2, which reports the truncation.
	mutating func finish() throws {
		if !isEncodingDecided {
			try decideEncoding()
		}
		if state == .processingInstruction, let declaration {
			try checkDeclaration(declaration)
		}
	}

	// MARK: - Encoding

	private mutating func take(_ byte: UInt8) throws {
		guard isEncodingDecided else {
			detectionBytes.append(byte)
			if detectionBytes.count == 4 {
				try decideEncoding()
			}
			return
		}
		try step(byte)
	}

	/// Refuses the encodings that libxml2 detects from the first up to 4 bytes, and skips a UTF-8 byte order mark.
	private mutating func decideEncoding() throws {
		guard !WebDAVXMLGuard.refusedSignatures.contains(detectionBytes), !WebDAVXMLGuard.utf16Signatures.contains(where: { detectionBytes.starts(with: $0) }) else {
			throw WebDAVXMLGuardError.unsupported(.encoding)
		}
		isEncodingDecided = true
		let byteOrderMarkLength = detectionBytes.starts(with: WebDAVXMLGuard.byteOrderMark) ? WebDAVXMLGuard.byteOrderMark.count : 0
		for byte in detectionBytes.dropFirst(byteOrderMarkLength) {
			try step(byte)
		}
		detectionBytes = []
	}

	/// Checks the encoding that an XML declaration names, if its value is complete.
	private func checkDeclaration(_ declaration: [UInt8]) throws {
		guard declaration.starts(with: "xml".utf8), declaration.count > 3, WebDAVXMLGuard.isWhitespace(declaration[3]), let name = WebDAVXMLGuard.encodingName(inDeclaration: declaration.dropFirst(3)) else {
			return
		}
		guard let lowercasedName = String(bytes: name, encoding: .ascii)?.lowercased(), WebDAVXMLGuard.encodingNames.contains(lowercasedName) else {
			throw WebDAVXMLGuardError.unsupported(.encoding)
		}
	}

	/// Reads the declaration's pseudo-attributes up to `encoding`, and returns `nil` if they are malformed or end before its value does.
	private static func encodingName(inDeclaration bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
		var index = bytes.startIndex
		func skipWhitespace() {
			while index < bytes.endIndex, isWhitespace(bytes[index]) {
				index += 1
			}
		}
		while true {
			skipWhitespace()
			let nameStart = index
			while index < bytes.endIndex, !isWhitespace(bytes[index]), bytes[index] != UInt8(ascii: "=") {
				index += 1
			}
			let name = bytes[nameStart ..< index]
			skipWhitespace()
			guard !name.isEmpty, index < bytes.endIndex, bytes[index] == UInt8(ascii: "=") else {
				return nil
			}
			index += 1
			skipWhitespace()
			guard index < bytes.endIndex, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") else {
				return nil
			}
			let quote = bytes[index]
			let valueStart = index + 1
			guard let valueEnd = bytes[valueStart...].firstIndex(of: quote) else {
				return nil
			}
			if name.elementsEqual("encoding".utf8) {
				return bytes[valueStart ..< valueEnd]
			}
			index = valueEnd + 1
		}
	}

	// MARK: - Markup

	private mutating func step(_ byte: UInt8) throws {
		switch state {
		case .content:
			contentStep(byte)
		case .reference:
			try referenceStep(byte)
		case .tagOpen:
			try tagOpenStep(byte)
		case .startTag:
			try startTagStep(byte)
		case .endTag:
			try endTagStep(byte)
		case .markup:
			try markupStep(byte)
		case .commentOpen:
			try commentOpenStep(byte)
		case let .cdataOpen(matched):
			try cdataOpenStep(byte, matched: matched)
		case .comment, .cdata, .processingInstruction:
			try delimitedStep(byte)
		}
		byteIndex += 1
	}

	private mutating func contentStep(_ byte: UInt8) {
		if byte == UInt8(ascii: "<") {
			openTag()
		} else if byte == UInt8(ascii: "&") {
			state = .reference
			length = 0
		}
	}

	/// libxml2 waits for the `;` wherever it comes, so every byte up to it counts, markup included.
	private mutating func referenceStep(_ byte: UInt8) throws {
		if byte == UInt8(ascii: ";") {
			state = .content
		} else {
			length += 1
			guard length <= WebDAVXMLLimits.maxReferenceLength else {
				throw WebDAVXMLGuardError.limitExceeded(.reference)
			}
		}
	}

	private mutating func openTag() {
		state = .tagOpen
		length = 1
	}

	private mutating func tagOpenStep(_ byte: UInt8) throws {
		switch byte {
		case UInt8(ascii: "/"):
			state = .endTag
			try countTagByte()
			name = Name(isNamespaceURI: false, literal: [])
		case UInt8(ascii: "?"):
			state = .processingInstruction
			startDelimitedContent()
			name = Name(isNamespaceURI: false, literal: Name.catalogTarget)
			declaration = byteIndex == 1 ? [] : nil
		case UInt8(ascii: "!"):
			state = .markup
		default:
			state = .startTag
			isInProlog = false
			attributeCount = 0
			quote = nil
			isNamespaceDeclarationPending = false
			name = Name(isNamespaceURI: false, literal: Name.namespacePrefix)
			try startTagStep(byte)
		}
	}

	private mutating func countTagByte() throws {
		length += 1
		guard length <= WebDAVXMLLimits.maxTagLength else {
			throw WebDAVXMLGuardError.limitExceeded(.tag)
		}
	}

	/// Outside a quoted value, a quote opens one and counts an attribute, and `>` ends the tag. Inside one, only the same quote closes it.
	private mutating func startTagStep(_ byte: UInt8) throws {
		try countTagByte()
		if let openQuote = quote {
			if byte == UInt8(ascii: "<") {
				throw WebDAVXMLGuardError.unsupported(.tagDelimiter)
			} else if byte == openQuote {
				quote = nil
				try registerName()
			} else {
				name?.append(byte)
			}
			return
		}
		if name != nil {
			guard WebDAVXMLGuard.endsTagName(byte) else {
				name?.append(byte)
				return
			}
			isNamespaceDeclarationPending = name?.declaresNamespace ?? false
			try registerName()
		}
		try startTagDelimiterStep(byte)
	}

	private mutating func startTagDelimiterStep(_ byte: UInt8) throws {
		switch byte {
		case UInt8(ascii: ">"):
			state = .content
		case UInt8(ascii: "\""), UInt8(ascii: "'"):
			attributeCount += 1
			guard attributeCount <= WebDAVXMLLimits.maxAttributeCount else {
				throw WebDAVXMLGuardError.limitExceeded(.attributes)
			}
			quote = byte
			if isNamespaceDeclarationPending {
				name = Name(isNamespaceURI: true, literal: [])
			}
			isNamespaceDeclarationPending = false
		case UInt8(ascii: "="), UInt8(ascii: "/"):
			break
		case _ where WebDAVXMLGuard.isWhitespace(byte):
			break
		default:
			name = Name(isNamespaceURI: false, literal: Name.namespacePrefix)
			isNamespaceDeclarationPending = false
			name?.append(byte)
		}
	}

	private mutating func endTagStep(_ byte: UInt8) throws {
		try countTagByte()
		guard byte != UInt8(ascii: "\""), byte != UInt8(ascii: "'") else {
			throw WebDAVXMLGuardError.unsupported(.tagDelimiter)
		}
		let endsName = byte == UInt8(ascii: ">") || WebDAVXMLGuard.isWhitespace(byte)
		if name != nil {
			if endsName {
				try registerName()
			} else {
				name?.append(byte)
			}
		}
		if byte == UInt8(ascii: ">") {
			state = .content
		}
	}

	private mutating func markupStep(_ byte: UInt8) throws {
		switch byte {
		case UInt8(ascii: "-"):
			state = .commentOpen
		case UInt8(ascii: "[") where !isInProlog:
			state = .cdataOpen(matched: 0)
		default:
			throw WebDAVXMLGuardError.unsupported(.doctype)
		}
	}

	private mutating func commentOpenStep(_ byte: UInt8) throws {
		guard byte == UInt8(ascii: "-") else {
			throw WebDAVXMLGuardError.unsupported(.doctype)
		}
		state = .comment
		startDelimitedContent()
	}

	private mutating func cdataOpenStep(_ byte: UInt8, matched: Int) throws {
		guard byte == WebDAVXMLGuard.cdataKeyword[matched] else {
			throw WebDAVXMLGuardError.unsupported(.doctype)
		}
		if matched + 1 == WebDAVXMLGuard.cdataKeyword.count {
			state = .cdata
			startDelimitedContent()
		} else {
			state = .cdataOpen(matched: matched + 1)
		}
	}

	// MARK: - Comments, CDATA Sections and Processing Instructions

	private mutating func startDelimitedContent() {
		length = 0
		closerRunLength = 0
	}

	/// Only the last 2 (`-`, `]`) or 1 (`?`) bytes of a trailing run can belong to the closing delimiter, so every byte before them counts as content as soon as it arrives.
	private mutating func delimitedStep(_ byte: UInt8) throws {
		let construct: WebDAVXMLConstruct = switch state {
		case .comment: .comment
		case .cdata: .cdata
		default: .processingInstruction
		}
		let (closerByte, closerLength) = WebDAVXMLGuard.closer(of: construct)
		if byte == UInt8(ascii: ">"), closerRunLength >= closerLength {
			try closeDelimited()
			return
		}
		closerRunLength = byte == closerByte ? closerRunLength + 1 : 0
		length += 1
		guard length - min(closerRunLength, closerLength) <= WebDAVXMLLimits.maxDelimitedLength else {
			throw WebDAVXMLGuardError.limitExceeded(construct)
		}
		if state == .processingInstruction {
			try processingInstructionStep(byte)
		}
	}

	/// The byte that ends the content before `>`, and how many of it the delimiter holds.
	private static func closer(of construct: WebDAVXMLConstruct) -> (byte: UInt8, length: Int) {
		switch construct {
		case .comment: (UInt8(ascii: "-"), 2)
		case .cdata: (UInt8(ascii: "]"), 2)
		default: (UInt8(ascii: "?"), 1)
		}
	}

	private mutating func processingInstructionStep(_ byte: UInt8) throws {
		if name != nil {
			if byte == UInt8(ascii: "?") || WebDAVXMLGuard.isWhitespace(byte) {
				if isInProlog, name?.isLiteral == true {
					throw WebDAVXMLGuardError.unsupported(.processingInstruction)
				}
				try registerName()
			} else {
				name?.append(byte)
			}
		}
		declaration?.append(byte)
	}

	private mutating func closeDelimited() throws {
		if state == .processingInstruction, let declaration {
			try checkDeclaration(declaration)
			self.declaration = nil
		}
		state = .content
	}

	// MARK: - Names

	private mutating func registerName() throws {
		guard let name else {
			return
		}
		self.name = nil
		guard name.length > 0, fingerprints.insert(name.fingerprint).inserted else {
			return
		}
		distinctNameLength += name.length
		guard fingerprints.count <= WebDAVXMLLimits.maxDistinctNames, distinctNameLength <= WebDAVXMLLimits.maxDistinctNameLength else {
			throw WebDAVXMLGuardError.limitExceeded(.names)
		}
	}

	private static func endsTagName(_ byte: UInt8) -> Bool {
		switch byte {
		case UInt8(ascii: "="), UInt8(ascii: "/"), UInt8(ascii: ">"), UInt8(ascii: "\""), UInt8(ascii: "'"):
			return true
		default:
			return isWhitespace(byte)
		}
	}

	private static func isWhitespace(_ byte: UInt8) -> Bool {
		return byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
	}
}
