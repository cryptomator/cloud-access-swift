//
//  DropboxJSONTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct DropboxJSONTests {
		@Test
		func serverModifiedIsParsedAsSwiftyDropboxDid() {
			for (string, bitPattern) in DropboxFixtures.serverModifiedDates {
				#expect(bitPattern == DropboxDate.date(from: string)?.timeIntervalSinceReferenceDate.bitPattern, "\(string)")
			}
			for string in DropboxFixtures.unparseableServerModifiedDates {
				#expect(DropboxDate.date(from: string) == nil, "\(string)")
			}
		}

		@Test
		func argumentHeaderIsPrintableASCIIAndDecodesBack() throws {
			for path in ["/😀/file.txt", "/ö", "/\u{7F}", #"/"quoted" \ name"#, "/\u{1}"] {
				let header = try DropboxArgument.header(Argument(path: path))

				#expect(header.utf8.allSatisfy { (0x20 ... 0x7E).contains($0) }, "\(header)")
				#expect(try Argument(path: path) == JSONDecoder().decode(Argument.self, from: Data(header.utf8)))
			}
			#expect(try DropboxArgument.header(Argument(path: "/\u{7F}")) == #"{"path":"\/\u007f"}"#)
		}

		@Test
		func metadataIsTypedByItsTag() throws {
			let folder = try DropboxJSON.decode(DropboxMetadata.self, from: Data(#"{".tag":"folder","name":"folder"}"#.utf8))
			let file = try DropboxJSON.decode(DropboxMetadata.self, from: Data(#"{".tag":"file","name":"file.txt","size":7,"server_modified":"2026-10-21T08:15:38Z"}"#.utf8))
			let untaggedFile = try DropboxJSON.decode(DropboxMetadata.self, from: Data(#"{"name":"file.txt","size":7,"server_modified":"2026-10-21T08:15:38Z"}"#.utf8))
			let deleted = try DropboxJSON.decode(DropboxMetadata.self, from: Data(#"{".tag":"deleted","name":"gone.txt"}"#.utf8))

			#expect(try folder.cloudItemType(untaggedAs: nil) == .folder)
			#expect(try file.cloudItemType(untaggedAs: nil) == .file)
			#expect(try DropboxDate.date(from: "2026-10-21T08:15:38Z") == file.lastModifiedDate)
			#expect(try untaggedFile.cloudItemType(untaggedAs: .file) == .file)
			#expect(throws: DropboxError.unexpectedContent) { try untaggedFile.cloudItemType(untaggedAs: nil) }
			#expect(throws: DropboxError.unexpectedContent) { try deleted.cloudItemType(untaggedAs: .file) }
		}

		/// Only a 401 for a suspension keeps its summary when the details aren't an object, so that no other decision changes for such a body.
		@Test
		func onlySuspensionSummaryIsKeptIfDetailsAreNoObject() {
			#expect(DropboxErrorResponse.summary(of: Data(#"{"error_summary":"user_suspended/..","error":"user_suspended"}"#.utf8), statusCode: 401) == "user_suspended/..")
			#expect(DropboxErrorResponse.summary(of: Data(#"{"error_summary":"invalid_access_token/..","error":"invalid_access_token"}"#.utf8), statusCode: 401) == nil)
			#expect(DropboxErrorResponse.summary(of: Data(#"{"error_summary":"too_many_write_operations/..","error":"too_many_write_operations"}"#.utf8), statusCode: 409) == nil)
			#expect(DropboxErrorResponse.summary(of: Data(#"{"error_summary":"user_suspended/..","error":"user_suspended"}"#.utf8), statusCode: 403) == nil)
			#expect(DropboxErrorResponse.decode(from: Data(#"{"error_summary":"user_suspended/..","error":"user_suspended"}"#.utf8)) == nil)
		}
	}
}

private struct Argument: Codable, Equatable {
	let path: String
}
