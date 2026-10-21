//
//  GoogleDriveJSONTests.swift
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

class GoogleDriveJSONTests: XCTestCase {
	func testModifiedTimeIsParsedAsTheGoogleAPIClientDid() {
		for (string, bitPattern) in GoogleDriveFixtures.modifiedTimes {
			XCTAssertEqual(bitPattern, GoogleDriveDate.date(fromRFC3339: string)?.timeIntervalSinceReferenceDate.bitPattern, string)
		}
	}

	func testUnparseableModifiedTimeHasNoDate() {
		XCTAssertNil(GoogleDriveDate.date(fromRFC3339: "yesterday"))
	}

	/// Numbers out of `Int`'s range would trap in the conversion or the offset arithmetic, whereas an absurd offset that fits is applied as the Google API client did.
	func testModifiedTimeWithOutOfRangeNumbersHasNoDate() {
		for string in ["2026-10-20T12:34:1e20Z", "2026-10-20T12:34:56+9223372036854775807:00", "2026-10-20T12:34:56+05:-9223372036854775808"] {
			XCTAssertNil(GoogleDriveDate.date(fromRFC3339: string), string)
		}
		XCTAssertEqual(Date(timeIntervalSince1970: -5_622_163_200), GoogleDriveDate.date(fromRFC3339: "2020-01-01T00:00:00+2000000:00"))
	}

	func testFileFields() throws {
		let file = try GoogleDriveJSON.decode(GoogleDriveFile.self, from: Data(#"{"mimeType":"text/plain","size":"9007199254740993"}"#.utf8))

		XCTAssertEqual(.file, file.cloudItemType)
		XCTAssertEqual(9_007_199_254_740_993, try file.sizeValue)
	}

	func testMimeTypeMapping() throws {
		let cases: [(String, CloudItemType)] = [
			(#"{"mimeType":"application/vnd.google-apps.folder"}"#, .folder),
			(#"{"mimeType":"application/vnd.google-apps.shortcut"}"#, .symlink),
			(#"{"mimeType":"application/vnd.google-apps.document"}"#, .file),
			("{}", .unknown)
		]
		for (json, expectedType) in cases {
			XCTAssertEqual(expectedType, try GoogleDriveJSON.decode(GoogleDriveFile.self, from: Data(json.utf8)).cloudItemType, json)
		}
	}

	func testUnparseableSizeThrows() throws {
		let file = try GoogleDriveJSON.decode(GoogleDriveFile.self, from: Data(#"{"size":"many"}"#.utf8))

		XCTAssertThrowsError(try file.sizeValue) { error in
			XCTAssertEqual(.unexpectedContent, error as? GoogleDriveError)
		}
	}
}
