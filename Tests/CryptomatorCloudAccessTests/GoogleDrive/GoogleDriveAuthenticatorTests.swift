//
//  GoogleDriveAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AppAuth
import Testing
@testable import CryptomatorCloudAccess
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct GoogleDriveAuthenticatorTests {
		@Test
		func driveAccessNeedsDriveScope() {
			#expect(GoogleDriveAuthenticator.grantsDriveAccess("https://www.googleapis.com/auth/drive openid https://www.googleapis.com/auth/userinfo.email"))
			for scopes in ["openid https://www.googleapis.com/auth/userinfo.email", "https://www.googleapis.com/auth/drive.file", nil] {
				#expect(!GoogleDriveAuthenticator.grantsDriveAccess(scopes), "\(scopes ?? "nil")")
			}
		}

		@Test
		func convertLoginFlowErrorWithCancellation() {
			for code in [OIDErrorCode.userCanceledAuthorizationFlow, .programCanceledAuthorizationFlow] {
				let error = NSError(domain: OIDGeneralErrorDomain, code: code.rawValue)

				#expect((GoogleDriveAuthenticator.convertLoginFlowError(error) as? CocoaError)?.code == .userCancelled, "\(code)")
			}
		}

		@Test
		func convertLoginFlowErrorWithDeniedAccess() {
			let error = NSError(domain: OIDOAuthAuthorizationErrorDomain, code: OIDErrorCodeOAuth.accessDenied.rawValue)

			#expect((GoogleDriveAuthenticator.convertLoginFlowError(error) as? CocoaError)?.code == .userCancelled)
		}

		@Test
		func convertLoginFlowErrorWithOtherError() {
			for error in [NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.networkError.rawValue), NSError(domain: OIDOAuthAuthorizationErrorDomain, code: OIDErrorCodeOAuth.invalidScope.rawValue)] {
				#expect(error == (GoogleDriveAuthenticator.convertLoginFlowError(error) as NSError))
			}
		}

		@MainActor
		@Test
		func cancellationCancelsLoginFlow() async throws {
			let started = TestSignal("started")
			let cancelled = TestSignal("cancelled")
			let login = Task { @MainActor in
				try await GoogleDriveAuthenticator.runLoginFlow { _ in
					started.fulfill()
					return { cancelled.fulfill() }
				}
			}
			await started.wait()

			login.cancel()

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: login) }
			await cancelled.wait()
		}
	}
}
