//
//  GoogleDriveTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 25.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import Foundation
import Testing

extension IntegrationTests.ProviderSpecific {
	@Suite(.enabled(if: IntegrationBackend.isSelected(.googleDrive)))
	struct GoogleDriveTests {
		/// Authorizes a request, because `canAuthorize` returns `true` as soon as any refresh token is set, without checking it online.
		@Test
		func authenticationWorksWithoutViewController() async throws {
			try await withIntegrationRetries(on: .googleDrive) {
				let credential = try GoogleDriveAuthenticatorMock.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: "GDriveCredentialTest")
				let authSession = try #require(credential.authSession)
				let request = try NSMutableURLRequest(url: #require(URL(string: "https://example.com")))
				try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
					authSession.authorizeRequest(request) { error in
						if let error {
							continuation.resume(throwing: error)
						} else {
							continuation.resume()
						}
					}
				}
			}
		}
	}
}
