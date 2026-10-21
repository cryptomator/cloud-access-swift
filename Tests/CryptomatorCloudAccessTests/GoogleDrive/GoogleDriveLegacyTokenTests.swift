//
//  GoogleDriveLegacyTokenTests.swift
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

class GoogleDriveLegacyTokenTests: XCTestCase {
	func testLoginsOfEveryGTMAppAuthVersionDecode() throws {
		let cases = [
			("1", GoogleDriveFixtures.gtmAppAuth1, GoogleDriveFixtures.gtmAppAuth1Expiry),
			("5", GoogleDriveFixtures.gtmAppAuth5, GoogleDriveFixtures.gtmAppAuth5Expiry),
			("6", GoogleDriveFixtures.gtmAppAuth6, GoogleDriveFixtures.gtmAppAuth6Expiry)
		]
		for (version, archive, expiry) in cases {
			let token = try GoogleDriveLegacyToken.decode(archive)

			XCTAssertEqual(OAuthToken(accessToken: "ACCESS-\(version)", refreshToken: "REFRESH-\(version)", expiresAt: expiry, username: GoogleDriveFixtures.email), token, version)
		}
	}

	func testLoginWithoutTokenResponseThrowsUnauthorized() {
		XCTAssertThrowsError(try GoogleDriveLegacyToken.decode(GoogleDriveFixtures.gtmAppAuth6WithoutTokenResponse)) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
	}

	func testOtherDataThrows() {
		for data in [Data((0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }), Data("bplist00".utf8)] {
			XCTAssertThrowsError(try GoogleDriveLegacyToken.decode(data)) { error in
				XCTAssertEqual(.unexpectedContent, error as? GoogleDriveError)
			}
		}
	}
}
