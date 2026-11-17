//
//  DropboxLegacyTokenTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct DropboxLegacyTokenTests {
		@Test
		func decodeShortLivedAccessTokenOfObjCSDK() throws {
			#expect(try OAuthToken(accessToken: "sl.short-lived-access-token", refreshToken: "refresh-token", expiresAt: Date(timeIntervalSince1970: 1_760_000_000)) == DropboxLegacyToken.decode(DropboxFixtures.objCShortLivedArchive))
		}

		@Test
		func decodeLongLivedAccessTokenOfObjCSDK() throws {
			#expect(try OAuthToken(accessToken: "long-lived-access-token", refreshToken: nil, expiresAt: nil) == DropboxLegacyToken.decode(DropboxFixtures.objCLongLivedArchive))
		}

		@Test
		func decodeShortLivedAccessTokenOfSwiftyDropbox() throws {
			#expect(try OAuthToken(accessToken: "sl.short-lived-access-token", refreshToken: "refresh-token", expiresAt: Date(timeIntervalSince1970: 1_760_000_000)) == DropboxLegacyToken.decode(DropboxFixtures.swiftyDropboxShortLived))
		}

		@Test
		func decodeLongLivedAccessTokenOfSwiftyDropbox() throws {
			#expect(try OAuthToken(accessToken: "long-lived-access-token", refreshToken: nil, expiresAt: nil) == DropboxLegacyToken.decode(DropboxFixtures.swiftyDropboxLongLived))
		}

		@Test
		func decodePlainAccessToken() throws {
			#expect(try OAuthToken(accessToken: "access-token", refreshToken: nil, expiresAt: nil) == DropboxLegacyToken.decode(Data("access-token".utf8)))
		}

		@Test
		func emptyDataIsUnauthorized() {
			#expect(throws: CloudProviderError.unauthorized) { try DropboxLegacyToken.decode(Data()) }
		}
	}
}
