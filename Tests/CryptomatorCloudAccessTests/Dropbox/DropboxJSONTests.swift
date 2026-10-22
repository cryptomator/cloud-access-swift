//
//  DropboxJSONTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DropboxJSONTests: XCTestCase {
	func testServerModifiedIsParsedAsSwiftyDropboxDid() {
		for (string, bitPattern) in DropboxFixtures.serverModifiedDates {
			XCTAssertEqual(bitPattern, DropboxDate.date(from: string)?.timeIntervalSinceReferenceDate.bitPattern, string)
		}
		for string in DropboxFixtures.unparseableServerModifiedDates {
			XCTAssertNil(DropboxDate.date(from: string), string)
		}
	}

	func testArgumentHeaderIsPrintableASCIIAndDecodesBack() throws {
		struct Argument: Codable, Equatable {
			let path: String
		}
		for path in ["/😀/file.txt", "/ö", "/\u{7F}", #"/"quoted" \ name"#, "/\u{1}"] {
			let header = try DropboxArgument.header(Argument(path: path))

			XCTAssertTrue(header.utf8.allSatisfy { (0x20 ... 0x7E).contains($0) }, header)
			XCTAssertEqual(Argument(path: path), try JSONDecoder().decode(Argument.self, from: Data(header.utf8)))
		}
		XCTAssertEqual(#"{"path":"\/\u007f"}"#, try DropboxArgument.header(Argument(path: "/\u{7F}")))
	}

	func testMetadataIsTypedByItsTag() throws {
		let folder = try DropboxJSON.decode(DropboxMetadata.self, from: Data(#"{".tag":"folder","name":"folder"}"#.utf8))
		let file = try DropboxJSON.decode(DropboxMetadata.self, from: Data(#"{".tag":"file","name":"file.txt","size":7,"server_modified":"2026-10-21T08:15:38Z"}"#.utf8))
		let untaggedFile = try DropboxJSON.decode(DropboxMetadata.self, from: Data(#"{"name":"file.txt","size":7,"server_modified":"2026-10-21T08:15:38Z"}"#.utf8))
		let deleted = try DropboxJSON.decode(DropboxMetadata.self, from: Data(#"{".tag":"deleted","name":"gone.txt"}"#.utf8))

		XCTAssertEqual(.folder, try folder.cloudItemType(untaggedAs: nil))
		XCTAssertEqual(.file, try file.cloudItemType(untaggedAs: nil))
		XCTAssertEqual(DropboxDate.date(from: "2026-10-21T08:15:38Z"), try file.lastModifiedDate)
		XCTAssertEqual(.file, try untaggedFile.cloudItemType(untaggedAs: .file))
		XCTAssertThrowsError(try untaggedFile.cloudItemType(untaggedAs: nil)) { error in
			XCTAssertEqual(.unexpectedContent, error as? DropboxError)
		}
		XCTAssertThrowsError(try deleted.cloudItemType(untaggedAs: .file)) { error in
			XCTAssertEqual(.unexpectedContent, error as? DropboxError)
		}
	}
}
