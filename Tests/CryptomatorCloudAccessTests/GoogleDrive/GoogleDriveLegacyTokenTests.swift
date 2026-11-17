//
//  GoogleDriveLegacyTokenTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct GoogleDriveLegacyTokenTests {
		@Test
		func loginsOfEveryGTMAppAuthVersionDecode() throws {
			let cases = [
				("1", GoogleDriveFixtures.gtmAppAuth1, GoogleDriveFixtures.gtmAppAuth1Expiry),
				("5", GoogleDriveFixtures.gtmAppAuth5, GoogleDriveFixtures.gtmAppAuth5Expiry),
				("6", GoogleDriveFixtures.gtmAppAuth6, GoogleDriveFixtures.gtmAppAuth6Expiry)
			]
			for (version, archive, expiry) in cases {
				let token = try GoogleDriveLegacyToken.decode(archive)

				#expect(OAuthToken(accessToken: "ACCESS-\(version)", refreshToken: "REFRESH-\(version)", expiresAt: expiry, username: GoogleDriveFixtures.email) == token, "\(version)")
			}
		}

		@Test
		func loginWithoutTokenResponseThrowsUnauthorized() {
			#expect(throws: CloudProviderError.unauthorized) { try GoogleDriveLegacyToken.decode(GoogleDriveFixtures.gtmAppAuth6WithoutTokenResponse) }
		}

		@Test
		func otherDataThrows() {
			for data in [Data((0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }), Data("bplist00".utf8)] {
				#expect(throws: GoogleDriveError.unexpectedContent) { try GoogleDriveLegacyToken.decode(data) }
			}
		}
	}
}
