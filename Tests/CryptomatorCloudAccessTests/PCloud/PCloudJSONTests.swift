//
//  PCloudJSONTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class PCloudJSONTests: XCTestCase {
	func testFileMetadata() throws {
		let metadata = try PCloudJSON.metadata(in: Data(#"{"result":0,"metadata":{"isfolder":false,"name":"a.txt","fileid":42,"parentfolderid":0,"modified":1792056600,"size":7}}"#.utf8))

		XCTAssertFalse(metadata.isFolder)
		XCTAssertEqual("a.txt", metadata.name)
		XCTAssertEqual(42, metadata.identifier)
		XCTAssertEqual(1_792_056_600, metadata.modified)
		XCTAssertEqual(7, metadata.size)
	}

	func testFolderListing() throws {
		let metadata = try PCloudJSON.metadata(in: Data(#"{"result":0,"metadata":{"isfolder":true,"name":"folder","folderid":3,"modified":1792056600,"contents":[{"isfolder":true,"name":"sub","folderid":4,"modified":1792056601},{"isfolder":false,"name":"b.txt","fileid":5,"modified":1792056602,"size":0}]}}"#.utf8))

		XCTAssertTrue(metadata.isFolder)
		XCTAssertEqual(3, metadata.identifier)
		XCTAssertNil(metadata.size)
		XCTAssertEqual(["sub", "b.txt"], metadata.contents?.map(\.name))
		XCTAssertEqual([4, 5], metadata.contents?.map(\.identifier))
	}

	func testUploadedMetadataReadsFirstElement() throws {
		let metadata = try PCloudJSON.uploadedMetadata(in: Data(#"{"result":0,"fileids":[42],"metadata":[{"isfolder":false,"name":"a.txt","fileid":42,"modified":1792056600,"size":7}]}"#.utf8))

		XCTAssertEqual(42, metadata.identifier)
	}

	func testUploadedMetadataWithoutElementIsUnexpectedContent() {
		XCTAssertThrowsError(try PCloudJSON.uploadedMetadata(in: Data(#"{"result":0,"metadata":[]}"#.utf8))) { error in
			XCTAssertEqual(.unexpectedContent, error as? PCloudError)
		}
	}

	func testAuthenticationCodesAreUnauthorized() {
		for code in [1000, 2000, 2094] {
			XCTAssertThrowsError(try PCloudJSON.result(of: Data(#"{"result":\#(code),"error":"Log in failed."}"#.utf8))) { error in
				XCTAssertEqual(.unauthorized, error as? CloudProviderError, "\(code)")
			}
		}
	}

	func testOtherCodeIsAPIError() {
		XCTAssertThrowsError(try PCloudJSON.result(of: Data(#"{"result":2041,"error":"Connection broken."}"#.utf8))) { error in
			XCTAssertEqual(.apiError(code: 2041, message: "Connection broken."), error as? PCloudError)
		}
	}

	func testSuccessfulResultReturnsBody() throws {
		let body = Data(#"{"result":0,"email":"user@example.com"}"#.utf8)

		XCTAssertEqual(body, try PCloudJSON.result(of: body))
		XCTAssertEqual("user@example.com", try PCloudJSON.email(in: body))
	}

	func testUnreadableBodyIsUnexpectedContent() {
		for body in [#"<html>Login</html>"#, #"{"error":"no result"}"#, #"{"result":"0"}"#, #"{"result":0,"metadata":{"isfolder":"no","name":"a.txt","fileid":42,"modified":1}}"#] {
			XCTAssertThrowsError(try PCloudJSON.metadata(in: PCloudJSON.result(of: Data(body.utf8))), body) { error in
				XCTAssertEqual(.unexpectedContent, error as? PCloudError, body)
			}
		}
	}

	// MARK: - Legacy Token

	func testLegacyTokenDecodesUserOfSDK() throws {
		let token = try PCloudLegacyToken.decode(Data(#"{"id":7,"token":"LEGACY","serverRegionId":2,"httpAPIHostName":"eapi.pcloud.com"}"#.utf8))

		XCTAssertEqual(OAuthToken(accessToken: "LEGACY", refreshToken: nil, expiresAt: nil, apiHost: "eapi.pcloud.com"), token)
	}

	func testLegacyTokenLowercasesHost() throws {
		let token = try PCloudLegacyToken.decode(Data(#"{"id":7,"token":"LEGACY","serverRegionId":2,"httpAPIHostName":"EAPI.PCLOUD.COM"}"#.utf8))

		XCTAssertEqual("eapi.pcloud.com", token.apiHost)
	}

	func testLegacyTokenWithHostOutsidePCloudThrows() {
		XCTAssertThrowsError(try PCloudLegacyToken.decode(Data(#"{"id":7,"token":"LEGACY","serverRegionId":2,"httpAPIHostName":"evil.example"}"#.utf8))) { error in
			XCTAssertEqual(.unexpectedContent, error as? PCloudError)
		}
	}
}
