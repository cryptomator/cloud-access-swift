//
//  DropboxLegacyTokenTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DropboxLegacyTokenTests: XCTestCase {
	func testDecodeShortLivedAccessTokenOfObjCSDK() throws {
		XCTAssertEqual(OAuthToken(accessToken: "sl.short-lived-access-token", refreshToken: "refresh-token", expiresAt: Date(timeIntervalSince1970: 1_760_000_000)), try DropboxLegacyToken.decode(DropboxFixtures.objCShortLivedArchive))
	}

	func testDecodeLongLivedAccessTokenOfObjCSDK() throws {
		XCTAssertEqual(OAuthToken(accessToken: "long-lived-access-token", refreshToken: nil, expiresAt: nil), try DropboxLegacyToken.decode(DropboxFixtures.objCLongLivedArchive))
	}

	func testDecodeShortLivedAccessTokenOfSwiftyDropbox() throws {
		XCTAssertEqual(OAuthToken(accessToken: "sl.short-lived-access-token", refreshToken: "refresh-token", expiresAt: Date(timeIntervalSince1970: 1_760_000_000)), try DropboxLegacyToken.decode(DropboxFixtures.swiftyDropboxShortLived))
	}

	func testDecodeLongLivedAccessTokenOfSwiftyDropbox() throws {
		XCTAssertEqual(OAuthToken(accessToken: "long-lived-access-token", refreshToken: nil, expiresAt: nil), try DropboxLegacyToken.decode(DropboxFixtures.swiftyDropboxLongLived))
	}

	func testDecodePlainAccessToken() throws {
		XCTAssertEqual(OAuthToken(accessToken: "access-token", refreshToken: nil, expiresAt: nil), try DropboxLegacyToken.decode(Data("access-token".utf8)))
	}

	func testEmptyDataIsUnauthorized() {
		XCTAssertThrowsError(try DropboxLegacyToken.decode(Data())) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
	}
}
