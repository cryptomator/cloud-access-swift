//
//  PCloudListingReaderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 09.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
@testable import CryptomatorCloudAccess

class PCloudListingReaderTests: XCTestCase {
	private static let chunkSizes = [1, HTTPClientSupport.temporaryFileBufferLength]

	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - Children and Folder

	func testFolderListing() throws {
		let listing = #"{"result":0,"metadata":{"isfolder":true,"name":"folder","folderid":3,"modified":1792056600,"contents":[{"isfolder":true,"name":"sub","folderid":4,"modified":1792056601},{"isfolder":false,"name":"b.txt","fileid":5,"modified":1792056602,"size":0}]}}"#

		for chunkSize in PCloudListingReaderTests.chunkSizes {
			let summary = try validate(listing, chunkSize: chunkSize)
			let folder = try PCloudJSON.folder(fromFields: summary.folderFields)
			let children = try children(of: listing, chunkSize: chunkSize)

			XCTAssertTrue(folder.isFolder)
			XCTAssertEqual(3, folder.identifier)
			XCTAssertNil(folder.size)
			XCTAssertEqual(["sub", "b.txt"], children.map(\.name))
			XCTAssertEqual([4, 5], children.map(\.identifier))
		}
	}

	func testReadsMembersInAnyOrderAndWithEscapedKeys() throws {
		let listing = #" { "m\u0065tadata" : { "cont\u0065nts" : [ {"isfolder":false,"name":"a.txt","fileid":5,"modified":1,"size":7} ] , "icon" : {"x":[1,{"y":null}]}, "n\u0061me" : "földer", "isfolder" : true , "folderid" : 3 , "modified" : 1792056600 } , "checksums" : [true, false] , "r\u0065sult" : 0 } "#

		for chunkSize in PCloudListingReaderTests.chunkSizes {
			let summary = try validate(listing, chunkSize: chunkSize)
			let folder = try PCloudJSON.folder(fromFields: summary.folderFields)

			XCTAssertEqual(.number(Data("0".utf8)), summary.result)
			XCTAssertEqual(.absent, summary.error)
			XCTAssertEqual(.object, summary.metadata)
			XCTAssertEqual(.objects, summary.contents)
			XCTAssertEqual("földer", folder.name)
			XCTAssertEqual(3, folder.identifier)
			XCTAssertEqual(["a.txt"], try children(of: listing, chunkSize: chunkSize).map(\.name))
		}
	}

	func testCapturesChildrenWithEscapesAndNestedValues() throws {
		let listing = PCloudMockResponse.folder(id: 0, contents: [
			#"{"isfolder":false,"name":"\u00e9\ud83d\ude00\/\n\"\\","fileid":5,"modified":1,"size":7,"x":{"y":[1,{"z":[]}],"w":"]}"}}"#,
			#"{"isfolder":true,"name":"sub","folderid":4,"modified":1}"#
		])

		for chunkSize in PCloudListingReaderTests.chunkSizes {
			XCTAssertEqual(["\u{e9}😀/\n\"\\", "sub"], try children(of: listing, chunkSize: chunkSize).map(\.name))
		}
	}

	func testReadsIdentifiersExactly() throws {
		let listing = PCloudMockResponse.folder(id: UInt64.max, contents: [PCloudMockResponse.fileEntry(id: (1 << 53) + 1, name: "a"), PCloudMockResponse.folderEntry(id: UInt64.max, name: "b")])

		for chunkSize in PCloudListingReaderTests.chunkSizes {
			let summary = try validate(listing, chunkSize: chunkSize)

			XCTAssertEqual(UInt64.max, try PCloudJSON.folder(fromFields: summary.folderFields).identifier)
			XCTAssertEqual([(1 << 53) + 1, UInt64.max], try children(of: listing, chunkSize: chunkSize).map(\.identifier))
		}
	}

	func testForEachChildStopsWhenBodyReturnsFalse() throws {
		let fileURL = try write(PCloudMockResponse.folder(id: 0, contents: ["a", "b", "c"].enumerated().map { PCloudMockResponse.fileEntry(id: UInt64($0), name: $1) }))
		var names = [String]()

		try PCloudListingReader.forEachChild(inFileAt: fileURL) { element in
			try names.append(PCloudJSON.child(in: element).name)
			return names.count < 2
		}

		XCTAssertEqual(["a", "b"], names)
	}

	// MARK: - Grammar

	func testRejectsEveryTruncation() throws {
		let listing = PCloudMockResponse.folder(id: 3, contents: [PCloudMockResponse.fileEntry(id: 5, name: "\u{00e9}\\\"😀"), PCloudMockResponse.folderEntry(id: 4, name: "sub")]) + " \n"
		let bytes = Data(listing.utf8)
		let rootEnd = try XCTUnwrap(bytes.lastIndex(of: UInt8(ascii: "}")))

		for length in 0 ..< bytes.count {
			let fileURL = try write(bytes.prefix(length))
			if length > rootEnd {
				XCTAssertNoThrow(try PCloudListingReader.validate(fileAt: fileURL, chunkSize: 3), "\(length)")
			} else {
				assertThrows(.unexpectedContent, reading: fileURL, chunkSize: 3)
			}
		}
	}

	func testRejectsWhatJSONDecoderRejectsBeforeDecoding() throws {
		let valid = PCloudMockResponse.folder(id: 0, contents: [#"{"isfolder":false,"name":"NAME","fileid":5,"modified":1,"size":7}"#])
		let invalidListings: [Data] = [
			Data(),
			Data("   ".utf8),
			Data("[]".utf8),
			Data((valid + "x").utf8),
			Data((valid + "{}").utf8),
			Data(valid.replacingOccurrences(of: "NAME", with: #"\u0"x""#).utf8),
			Data(valid.replacingOccurrences(of: "NAME", with: #"\u000"#).utf8),
			Data(valid.replacingOccurrences(of: "\"size\":7", with: "\"size\":+1").utf8),
			Data(valid.replacingOccurrences(of: "\"size\":7", with: "\"size\":.5").utf8),
			Data(valid.replacingOccurrences(of: "\"size\":7", with: "\"size\":1x").utf8),
			Data(valid.replacingOccurrences(of: "\"size\":7", with: "\"size\":nul").utf8),
			Data(valid.replacingOccurrences(of: "\"size\":7", with: "\"size\":\u{0C}7").utf8),
			Data(valid.replacingOccurrences(of: "[{", with: "[,{").utf8),
			Data(valid.replacingOccurrences(of: "{\"result\"", with: "{,\"result\"").utf8),
			Data(valid.replacingOccurrences(of: "{\"result\"", with: #"{"\ud800":0,"result""#).utf8),
			Data(valid.utf8).replacing(Data("{\"result\"".utf8), with: Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x30, 0x2C, 0x22]) + Data("result\"".utf8)),
			Data(valid.utf8).replacing(Data("\"size\":7".utf8), with: Data("\"size\":7".utf8) + Data([0xC3, 0xA9])),
			Data([0xEF, 0xBB]) + Data(valid.utf8)
		]

		for listing in invalidListings {
			let fileURL = try write(listing)
			for chunkSize in PCloudListingReaderTests.chunkSizes {
				assertThrows(.unexpectedContent, reading: fileURL, chunkSize: chunkSize)
			}
		}
	}

	func testLeavesContentOfStringsAndSpellingOfNumbersToDecoding() throws {
		let longKey = String(repeating: "k", count: 4 * 1024)
		let listing = Data(PCloudMockResponse.folder(id: 3, contents: [#"{"isfolder":false,"name":"a.txt","fileid":5,"modified":1,"size":7,"icon":"\ud800\a\uZZZZ\u{01}\n","x":{"\udc00":[01,1-2,--,1e,1.2.3,1E5,1e+5,-1.5E-3]},"\#(longKey)":0}"#]).utf8)
			.replacing(Data("\\n".utf8), with: Data([0x0A, 0xFF, 0xC0, 0xAF]))
			.replacing(Data(#""result":0"#.utf8), with: Data(#""other":["\udc00",{"\#(longKey)":0}],"result":0"#.utf8))
		let fileURL = try write(listing)

		for chunkSize in PCloudListingReaderTests.chunkSizes {
			XCTAssertEqual(.object, try PCloudListingReader.validate(fileAt: fileURL, chunkSize: chunkSize).metadata)
			var names = [String]()
			try PCloudListingReader.forEachChild(inFileAt: fileURL, chunkSize: chunkSize) { element in
				try names.append(PCloudJSON.child(in: element).name)
				return true
			}
			XCTAssertEqual(["a.txt"], names)
		}
	}

	func testAcceptsByteOrderMarkAndTrailingCommas() throws {
		let listing = "\u{FEFF}" + #"{"result":0,"metadata":{"isfolder":true,"name":"folder","folderid":3,"modified":1,"contents":[{"isfolder":true,"name":"sub","folderid":4,"modified":1,},],},}"#

		for chunkSize in PCloudListingReaderTests.chunkSizes {
			let summary = try validate(listing, chunkSize: chunkSize)

			XCTAssertEqual(3, try PCloudJSON.folder(fromFields: summary.folderFields).identifier)
			XCTAssertEqual(["sub"], try children(of: listing, chunkSize: chunkSize).map(\.name))
		}
	}

	func testFirstOccurrenceOfDuplicateMembersCounts() throws {
		let listing = #"{"result":0,"result":"x","error":"first","error":5,"metadata":{"isfolder":true,"name":"first","folderid":3,"modified":1,"contents":[{"isfolder":true,"name":"a","folderid":4,"modified":1}],"name":"second","contents":[{"isfolder":true,"name":"b","folderid":5,"modified":1}],"contents":null},"metadata":null}"#

		for chunkSize in PCloudListingReaderTests.chunkSizes {
			let summary = try validate(listing, chunkSize: chunkSize)

			XCTAssertEqual(.number(Data("0".utf8)), summary.result)
			XCTAssertEqual(.string(Data(#""first""#.utf8)), summary.error)
			XCTAssertEqual(.object, summary.metadata)
			XCTAssertEqual(.objects, summary.contents)
			XCTAssertEqual("first", try PCloudJSON.folder(fromFields: summary.folderFields).name)
			XCTAssertEqual(["a"], try children(of: listing, chunkSize: chunkSize).map(\.name))
		}
	}

	// MARK: - Recorded Kinds

	func testRecordsKindsOfMembers() throws {
		let longString = String(repeating: "x", count: 4 * 1024)
		let longArray = "[" + Array(repeating: "1", count: 4 * 1024).joined(separator: ",") + "]"
		let longZero = "0." + String(repeating: "0", count: 38)
		let folder = #"{"isfolder":true,"name":"f","folderid":3,"modified":1}"#
		let cases: [(listing: String, expected: PCloudListingReader.Summary)] = [
			(#"{"result":2005,"error":"Directory does not exist."}"#, summary(result: .number(Data("2005".utf8)), error: .string(Data(#""Directory does not exist.""#.utf8)))),
			(#"{"result":2005,"error":null}"#, summary(result: .number(Data("2005".utf8)), error: .null)),
			(#"{"result":2005,"error":"\#(longString)"}"#, summary(result: .number(Data("2005".utf8)), error: .oversizedString)),
			(#"{"result":2005,"error":\#(longArray)}"#, summary(result: .number(Data("2005".utf8)), error: .other)),
			(#"{"result":\#(longZero)}"#, summary(result: .number(Data(longZero.utf8)))),
			(#"{"result":"0"}"#, summary(result: .other)),
			(#"{"error":"x"}"#, summary(error: .string(Data(#""x""#.utf8)))),
			(#"{"result":0}"#, summary(result: .number(Data("0".utf8)))),
			(#"{"result":0,"metadata":null}"#, summary(result: .number(Data("0".utf8)), metadata: .null)),
			(#"{"result":0,"metadata":[]}"#, summary(result: .number(Data("0".utf8)), metadata: .other)),
			(#"{"result":0,"metadata":\#(folder)}"#, summary(result: .number(Data("0".utf8)), metadata: .object)),
			(#"{"result":0,"metadata":{"\ud800":0}}"#, summary(result: .number(Data("0".utf8)), metadata: .other)),
			(#"{"result":0,"metadata":{"contents":null}}"#, summary(result: .number(Data("0".utf8)), metadata: .object, contents: .null)),
			(#"{"result":0,"metadata":{"contents":[{},1]}}"#, summary(result: .number(Data("0".utf8)), metadata: .object, contents: .other)),
			(#"{"result":0,"metadata":{"contents":{}}}"#, summary(result: .number(Data("0".utf8)), metadata: .object, contents: .other))
		]

		for (listing, expected) in cases {
			for chunkSize in PCloudListingReaderTests.chunkSizes {
				var summary = try validate(listing, chunkSize: chunkSize)
				summary.folderFields = Data()

				XCTAssertEqual(expected, summary, listing.prefix(100) + "…")
			}
		}
	}

	// MARK: - Caps

	func testOversizedListingsThrowListingTooLarge() throws {
		let longName = String(repeating: "a", count: 64 * 1024)
		let deepValue = String(repeating: "[", count: 64) + String(repeating: "]", count: 64)
		let listings = [
			PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: longName)]),
			PCloudMockResponse.folder(id: 0, contents: [#"{"x":\#(deepValue)}"#]),
			#"{"\#(String(repeating: "k", count: 4 * 1024))":0,"result":0}"#,
			PCloudMockResponse.folder(id: 0, name: String(repeating: "a", count: 64 * 1024)),
			#"{"result":0.\#(String(repeating: "0", count: 4 * 1024))}"#
		]

		for listing in listings {
			try assertThrows(.listingTooLarge, reading: write(listing), chunkSize: HTTPClientSupport.temporaryFileBufferLength)
		}
	}

	func testSkipsLargeValuesItDoesNotRead() throws {
		let listing = #"{"result":0,"other":"\#(String(repeating: "a", count: 2 * 1024 * 1024))","metadata":{"isfolder":true,"name":"f","folderid":3,"modified":1,"contents":[]}}"#

		let summary = try validate(listing, chunkSize: HTTPClientSupport.temporaryFileBufferLength)

		XCTAssertEqual(.objects, summary.contents)
	}

	// MARK: - Helpers

	private func summary(result: PCloudListingReader.Summary.Result = .absent, error: PCloudListingReader.Summary.Message = .absent, metadata: PCloudListingReader.Summary.Metadata = .absent, contents: PCloudListingReader.Summary.Contents = .absent) -> PCloudListingReader.Summary {
		var summary = PCloudListingReader.Summary()
		summary.result = result
		summary.error = error
		summary.metadata = metadata
		summary.contents = contents
		return summary
	}

	private func write(_ listing: String) throws -> URL {
		return try write(Data(listing.utf8))
	}

	private func write(_ data: Data) throws -> URL {
		let fileURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		try data.write(to: fileURL)
		return fileURL
	}

	private func validate(_ listing: String, chunkSize: Int) throws -> PCloudListingReader.Summary {
		return try PCloudListingReader.validate(fileAt: write(listing), chunkSize: chunkSize)
	}

	private func children(of listing: String, chunkSize: Int) throws -> [PCloudMetadata] {
		var children = [PCloudMetadata]()
		try PCloudListingReader.forEachChild(inFileAt: write(listing), chunkSize: chunkSize) { element in
			try children.append(PCloudJSON.child(in: element))
			return true
		}
		return children
	}

	private func assertThrows(_ expected: PCloudError, reading fileURL: URL, chunkSize: Int, file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertThrowsError(try PCloudListingReader.validate(fileAt: fileURL, chunkSize: chunkSize), file: file, line: line) { error in
			XCTAssertEqual(expected, error as? PCloudError, file: file, line: line)
		}
	}
}
