//
//  MicrosoftGraphAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 22.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import MSAL
import Testing
@testable import CryptomatorCloudAccess
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	@MainActor
	struct MicrosoftGraphAuthenticatorTests {
		@Test
		func returnsAccountIdentifier() async throws {
			let identifier = try await MicrosoftGraphAuthenticator.acquireAccountIdentifier(acquire: { completion in
				completion("ACCOUNT", nil)
			}, cancel: {})

			#expect(identifier == "ACCOUNT")
		}

		@Test
		func cancellationCancelsWebAuthSession() async throws {
			let started = TestSignal("started")
			let cancelled = TestSignal("cancelled")
			let login = Task { @MainActor in
				try await MicrosoftGraphAuthenticator.acquireAccountIdentifier(acquire: { _ in
					started.fulfill()
				}, cancel: {
					cancelled.fulfill()
				})
			}
			await started.wait()

			login.cancel()

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: login) }
			await cancelled.wait()
		}

		@Test
		func testConvertLoginFlowError() {
			#expect((MicrosoftGraphAuthenticator.convertLoginFlowError(NSError(domain: MSALErrorDomain, code: MSALError.userCanceled.rawValue)) as? CocoaError)?.code == .userCancelled)
			#expect((MicrosoftGraphAuthenticator.convertLoginFlowError(NSError(domain: MSALErrorDomain, code: MSALError.serverDeclinedScopes.rawValue)) as? MicrosoftGraphAuthenticatorError) == .serverDeclinedScopes, "Declined scopes aren't converted")
			#expect((MicrosoftGraphAuthenticator.convertLoginFlowError(nil) as? MicrosoftGraphAuthenticatorError) == .missingAccountIdentifier, "A login without an account and without an error isn't converted")
		}
	}
}
