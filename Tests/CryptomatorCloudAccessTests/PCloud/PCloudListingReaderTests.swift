//
//  PCloudListingReaderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 09.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class PCloudListingReaderTests {
		private static let chunkSizes = [1, HTTPClientSupport.temporaryFileBufferLength]

		private let tmpDirURL: URL

		init() throws {
			self.tmpDirURL = try makeTemporaryDirectory()
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		// MARK: - Children and Folder

		@Test
		func folderListing() throws {
			let listing = #"{"result":0,"metadata":{"isfolder":true,"name":"folder","folderid":3,"modified":1792056600,"contents":[{"isfolder":true,"name":"sub","folderid":4,"modified":1792056601},{"isfolder":false,"name":"b.txt","fileid":5,"modified":1792056602,"size":0}]}}"#

			for chunkSize in PCloudListingReaderTests.chunkSizes {
				let summary = try validate(listing, chunkSize: chunkSize)
				let folder = try PCloudJSON.folder(fromFields: summary.folderFields)
				let children = try children(of: listing, chunkSize: chunkSize)

				#expect(folder.isFolder)
				#expect(folder.identifier == 3)
				#expect(folder.size == nil)
				#expect(children.map(\.name) == ["sub", "b.txt"])
				#expect(children.map(\.identifier) == [4, 5])
			}
		}

		@Test
		func readsMembersInAnyOrderAndWithEscapedKeys() throws {
			let listing = #" { "m\u0065tadata" : { "cont\u0065nts" : [ {"isfolder":false,"name":"a.txt","fileid":5,"modified":1,"size":7} ] , "icon" : {"x":[1,{"y":null}]}, "n\u0061me" : "földer", "isfolder" : true , "folderid" : 3 , "modified" : 1792056600 } , "checksums" : [true, false] , "r\u0065sult" : 0 } "#

			for chunkSize in PCloudListingReaderTests.chunkSizes {
				let summary = try validate(listing, chunkSize: chunkSize)
				let folder = try PCloudJSON.folder(fromFields: summary.folderFields)

				#expect(.number(Data("0".utf8)) == summary.result)
				#expect(summary.error == .absent)
				#expect(summary.metadata == .object)
				#expect(summary.contents == .objects)
				#expect(folder.name == "földer")
				#expect(folder.identifier == 3)
				#expect(try children(of: listing, chunkSize: chunkSize).map(\.name) == ["a.txt"])
			}
		}

		@Test
		func capturesChildrenWithEscapesAndNestedValues() throws {
			let listing = PCloudMockResponse.folder(id: 0, contents: [
				#"{"isfolder":false,"name":"\u00e9\ud83d\ude00\/\n\"\\","fileid":5,"modified":1,"size":7,"x":{"y":[1,{"z":[]}],"w":"]}"}}"#,
				#"{"isfolder":true,"name":"sub","folderid":4,"modified":1}"#
			])

			for chunkSize in PCloudListingReaderTests.chunkSizes {
				#expect(try children(of: listing, chunkSize: chunkSize).map(\.name) == ["\u{e9}😀/\n\"\\", "sub"])
			}
		}

		@Test
		func readsIdentifiersExactly() throws {
			let listing = PCloudMockResponse.folder(id: UInt64.max, contents: [PCloudMockResponse.fileEntry(id: (1 << 53) + 1, name: "a"), PCloudMockResponse.folderEntry(id: UInt64.max, name: "b")])

			for chunkSize in PCloudListingReaderTests.chunkSizes {
				let summary = try validate(listing, chunkSize: chunkSize)

				#expect(try UInt64.max == PCloudJSON.folder(fromFields: summary.folderFields).identifier)
				#expect(try [(1 << 53) + 1, UInt64.max] == children(of: listing, chunkSize: chunkSize).map(\.identifier))
			}
		}

		@Test
		func forEachChildStopsWhenBodyReturnsFalse() throws {
			let fileURL = try makeLocalFile(in: tmpDirURL, content: PCloudMockResponse.folder(id: 0, contents: ["a", "b", "c"].enumerated().map { PCloudMockResponse.fileEntry(id: UInt64($0), name: $1) }))
			var names = [String]()

			try PCloudListingReader.forEachChild(inFileAt: fileURL) { element in
				try names.append(PCloudJSON.child(in: element).name)
				return names.count < 2
			}

			#expect(names == ["a", "b"])
		}

		// MARK: - Grammar

		@Test
		func rejectsEveryTruncation() throws {
			let listing = PCloudMockResponse.folder(id: 3, contents: [PCloudMockResponse.fileEntry(id: 5, name: "\u{00e9}\\\"😀"), PCloudMockResponse.folderEntry(id: 4, name: "sub")]) + " \n"
			let bytes = Data(listing.utf8)
			let rootEnd = try #require(bytes.lastIndex(of: UInt8(ascii: "}")))

			for length in 0 ..< bytes.count {
				let fileURL = try makeLocalFile(in: tmpDirURL, data: bytes.prefix(length))
				if length > rootEnd {
					#expect(throws: Never.self, "\(length)") { try PCloudListingReader.validate(fileAt: fileURL, chunkSize: 3) }
				} else {
					assertThrows(.unexpectedContent, reading: fileURL, chunkSize: 3)
				}
			}
		}

		@Test
		func rejectsWhatJSONDecoderRejectsBeforeDecoding() throws {
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
				let fileURL = try makeLocalFile(in: tmpDirURL, data: listing)
				for chunkSize in PCloudListingReaderTests.chunkSizes {
					assertThrows(.unexpectedContent, reading: fileURL, chunkSize: chunkSize)
				}
			}
		}

		@Test
		func leavesContentOfStringsAndSpellingOfNumbersToDecoding() throws {
			let longKey = String(repeating: "k", count: 4 * 1024)
			let listing = Data(PCloudMockResponse.folder(id: 3, contents: [#"{"isfolder":false,"name":"a.txt","fileid":5,"modified":1,"size":7,"icon":"\ud800\a\uZZZZ\u{01}\n","x":{"\udc00":[01,1-2,--,1e,1.2.3,1E5,1e+5,-1.5E-3]},"\#(longKey)":0}"#]).utf8)
				.replacing(Data("\\n".utf8), with: Data([0x0A, 0xFF, 0xC0, 0xAF]))
				.replacing(Data(#""result":0"#.utf8), with: Data(#""other":["\udc00",{"\#(longKey)":0}],"result":0"#.utf8))
			let fileURL = try makeLocalFile(in: tmpDirURL, data: listing)

			for chunkSize in PCloudListingReaderTests.chunkSizes {
				#expect(try PCloudListingReader.validate(fileAt: fileURL, chunkSize: chunkSize).metadata == .object)
				var names = [String]()
				try PCloudListingReader.forEachChild(inFileAt: fileURL, chunkSize: chunkSize) { element in
					try names.append(PCloudJSON.child(in: element).name)
					return true
				}
				#expect(names == ["a.txt"])
			}
		}

		@Test
		func acceptsByteOrderMarkAndTrailingCommas() throws {
			let listing = "\u{FEFF}" + #"{"result":0,"metadata":{"isfolder":true,"name":"folder","folderid":3,"modified":1,"contents":[{"isfolder":true,"name":"sub","folderid":4,"modified":1,},],},}"#

			for chunkSize in PCloudListingReaderTests.chunkSizes {
				let summary = try validate(listing, chunkSize: chunkSize)

				#expect(try PCloudJSON.folder(fromFields: summary.folderFields).identifier == 3)
				#expect(try children(of: listing, chunkSize: chunkSize).map(\.name) == ["sub"])
			}
		}

		@Test
		func firstOccurrenceOfDuplicateMembersCounts() throws {
			let listing = #"{"result":0,"result":"x","error":"first","error":5,"metadata":{"isfolder":true,"name":"first","folderid":3,"modified":1,"contents":[{"isfolder":true,"name":"a","folderid":4,"modified":1}],"name":"second","contents":[{"isfolder":true,"name":"b","folderid":5,"modified":1}],"contents":null},"metadata":null}"#

			for chunkSize in PCloudListingReaderTests.chunkSizes {
				let summary = try validate(listing, chunkSize: chunkSize)

				#expect(.number(Data("0".utf8)) == summary.result)
				#expect(.string(Data(#""first""#.utf8)) == summary.error)
				#expect(summary.metadata == .object)
				#expect(summary.contents == .objects)
				#expect(try PCloudJSON.folder(fromFields: summary.folderFields).name == "first")
				#expect(try children(of: listing, chunkSize: chunkSize).map(\.name) == ["a"])
			}
		}

		// MARK: - Recorded Kinds

		@Test
		func recordsKindsOfMembers() throws {
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

					#expect(expected == summary, "\(listing.prefix(100) + "…")")
				}
			}
		}

		// MARK: - Caps

		@Test
		func oversizedListingsThrowListingTooLarge() throws {
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
				try assertThrows(.listingTooLarge, reading: makeLocalFile(in: tmpDirURL, content: listing), chunkSize: HTTPClientSupport.temporaryFileBufferLength)
			}
		}

		@Test
		func skipsLargeValuesItDoesNotRead() throws {
			let listing = #"{"result":0,"other":"\#(String(repeating: "a", count: 2 * 1024 * 1024))","metadata":{"isfolder":true,"name":"f","folderid":3,"modified":1,"contents":[]}}"#

			let summary = try validate(listing, chunkSize: HTTPClientSupport.temporaryFileBufferLength)

			#expect(summary.contents == .objects)
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

		private func validate(_ listing: String, chunkSize: Int) throws -> PCloudListingReader.Summary {
			return try PCloudListingReader.validate(fileAt: makeLocalFile(in: tmpDirURL, content: listing), chunkSize: chunkSize)
		}

		private func children(of listing: String, chunkSize: Int) throws -> [PCloudMetadata] {
			var children = [PCloudMetadata]()
			try PCloudListingReader.forEachChild(inFileAt: makeLocalFile(in: tmpDirURL, content: listing), chunkSize: chunkSize) { element in
				try children.append(PCloudJSON.child(in: element))
				return true
			}
			return children
		}

		private func assertThrows(_ expected: PCloudError, reading fileURL: URL, chunkSize: Int, sourceLocation: SourceLocation = #_sourceLocation) {
			#expect(throws: expected, sourceLocation: sourceLocation) { try PCloudListingReader.validate(fileAt: fileURL, chunkSize: chunkSize) }
		}
	}
}
