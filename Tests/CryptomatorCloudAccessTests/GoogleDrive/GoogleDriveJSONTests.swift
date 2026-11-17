//
//  GoogleDriveJSONTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct GoogleDriveJSONTests {
		@Test
		func modifiedTimeIsParsedAsTheGoogleAPIClientDid() {
			for (string, bitPattern) in GoogleDriveFixtures.modifiedTimes {
				#expect(bitPattern == GoogleDriveDate.date(fromRFC3339: string)?.timeIntervalSinceReferenceDate.bitPattern, "\(string)")
			}
		}

		@Test
		func unparseableModifiedTimeHasNoDate() {
			#expect(GoogleDriveDate.date(fromRFC3339: "yesterday") == nil)
		}

		/// Numbers out of `Int`'s range would trap in the conversion or the offset arithmetic, whereas an absurd offset that fits is applied as the Google API client did.
		@Test
		func modifiedTimeWithOutOfRangeNumbersHasNoDate() {
			for string in ["2026-10-20T12:34:1e20Z", "2026-10-20T12:34:56+9223372036854775807:00", "2026-10-20T12:34:56+05:-9223372036854775808"] {
				#expect(GoogleDriveDate.date(fromRFC3339: string) == nil, "\(string)")
			}
			#expect(Date(timeIntervalSince1970: -5_622_163_200) == GoogleDriveDate.date(fromRFC3339: "2020-01-01T00:00:00+2000000:00"))
		}

		@Test
		func fileFields() throws {
			let file = try GoogleDriveJSON.decode(GoogleDriveFile.self, from: Data(#"{"mimeType":"text/plain","size":"9007199254740993"}"#.utf8))

			#expect(file.cloudItemType == .file)
			#expect(try file.sizeValue == 9_007_199_254_740_993)
		}

		@Test
		func mimeTypeMapping() throws {
			let cases: [(String, CloudItemType)] = [
				(#"{"mimeType":"application/vnd.google-apps.folder"}"#, .folder),
				(#"{"mimeType":"application/vnd.google-apps.shortcut"}"#, .symlink),
				(#"{"mimeType":"application/vnd.google-apps.document"}"#, .file),
				("{}", .unknown)
			]
			for (json, expectedType) in cases {
				#expect(try expectedType == GoogleDriveJSON.decode(GoogleDriveFile.self, from: Data(json.utf8)).cloudItemType, "\(json)")
			}
		}

		@Test
		func unparseableSizeThrows() throws {
			let file = try GoogleDriveJSON.decode(GoogleDriveFile.self, from: Data(#"{"size":"many"}"#.utf8))

			#expect(throws: GoogleDriveError.unexpectedContent) { try file.sizeValue }
		}
	}
}
