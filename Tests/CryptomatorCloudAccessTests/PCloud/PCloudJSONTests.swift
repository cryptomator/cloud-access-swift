//
//  PCloudJSONTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct PCloudJSONTests {
		@Test
		func fileMetadata() throws {
			let metadata = try PCloudJSON.metadata(in: Data(#"{"result":0,"metadata":{"isfolder":false,"name":"a.txt","fileid":42,"parentfolderid":0,"modified":1792056600,"size":7}}"#.utf8))

			#expect(!metadata.isFolder)
			#expect(metadata.name == "a.txt")
			#expect(metadata.identifier == 42)
			#expect(metadata.modified == 1_792_056_600)
			#expect(metadata.size == 7)
		}

		@Test
		func uploadedMetadataReadsFirstElement() throws {
			let metadata = try PCloudJSON.uploadedMetadata(in: Data(#"{"result":0,"fileids":[42],"metadata":[{"isfolder":false,"name":"a.txt","fileid":42,"modified":1792056600,"size":7}]}"#.utf8))

			#expect(metadata.identifier == 42)
		}

		@Test
		func uploadedMetadataWithoutElementIsUnexpectedContent() {
			#expect(throws: PCloudError.unexpectedContent) { try PCloudJSON.uploadedMetadata(in: Data(#"{"result":0,"metadata":[]}"#.utf8)) }
		}

		@Test
		func otherCodeIsAPIError() {
			#expect(throws: PCloudError.apiError(code: 2041, message: "Connection broken.")) { try PCloudJSON.result(of: Data(#"{"result":2041,"error":"Connection broken."}"#.utf8)) }
		}

		@Test
		func successfulResultReturnsBody() throws {
			let body = Data(#"{"result":0,"email":"user@example.com"}"#.utf8)

			#expect(try body == PCloudJSON.result(of: body))
			#expect(try PCloudJSON.email(in: body) == "user@example.com")
		}

		@Test
		func unreadableBodyIsUnexpectedContent() {
			for body in [#"<html>Login</html>"#, #"{"error":"no result"}"#, #"{"result":"0"}"#, #"{"result":0,"metadata":{"isfolder":"no","name":"a.txt","fileid":42,"modified":1}}"#] {
				#expect(throws: PCloudError.unexpectedContent, "\(body)") { try PCloudJSON.metadata(in: PCloudJSON.result(of: Data(body.utf8))) }
			}
		}

		// MARK: - Legacy Token

		@Test
		func legacyTokenDecodesUserOfSDK() throws {
			let token = try PCloudLegacyToken.decode(Data(#"{"id":7,"token":"LEGACY","serverRegionId":2,"httpAPIHostName":"eapi.pcloud.com"}"#.utf8))

			#expect(OAuthToken(accessToken: "LEGACY", refreshToken: nil, expiresAt: nil, apiHost: "eapi.pcloud.com") == token)
		}

		@Test
		func legacyTokenLowercasesHost() throws {
			let token = try PCloudLegacyToken.decode(Data(#"{"id":7,"token":"LEGACY","serverRegionId":2,"httpAPIHostName":"EAPI.PCLOUD.COM"}"#.utf8))

			#expect(token.apiHost == "eapi.pcloud.com")
		}

		@Test
		func legacyTokenWithHostOutsidePCloudThrows() {
			#expect(throws: PCloudError.unexpectedContent) { try PCloudLegacyToken.decode(Data(#"{"id":7,"token":"LEGACY","serverRegionId":2,"httpAPIHostName":"evil.example"}"#.utf8)) }
		}
	}
}
