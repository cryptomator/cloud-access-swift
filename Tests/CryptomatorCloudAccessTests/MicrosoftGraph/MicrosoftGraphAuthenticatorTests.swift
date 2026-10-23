//
//  MicrosoftGraphAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 22.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import MSAL
import XCTest
@testable import CryptomatorCloudAccess
#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif

@MainActor
class MicrosoftGraphAuthenticatorTests: XCTestCase {
	func testReturnsAccountIdentifier() async throws {
		let identifier = try await MicrosoftGraphAuthenticator.acquireAccountIdentifier(acquire: { completion in
			completion("ACCOUNT", nil)
		}, cancel: {})

		XCTAssertEqual("ACCOUNT", identifier)
	}

	func testCancellationCancelsWebAuthSession() async throws {
		let started = XCTestExpectation(description: "started")
		let cancelled = XCTestExpectation(description: "cancelled")
		let login = Task { @MainActor in
			try await MicrosoftGraphAuthenticator.acquireAccountIdentifier(acquire: { _ in
				started.fulfill()
			}, cancel: {
				cancelled.fulfill()
			})
		}
		await fulfillment(of: [started], timeout: testWaitTimeout)

		login.cancel()

		await XCTAssertThrowsErrorAsync(try await value(of: login)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		await fulfillment(of: [cancelled], timeout: testWaitTimeout)
	}

	func testConvertLoginFlowError() {
		XCTAssertEqual(.userCancelled, (MicrosoftGraphAuthenticator.convertLoginFlowError(NSError(domain: MSALErrorDomain, code: MSALError.userCanceled.rawValue)) as? CocoaError)?.code)
		guard case MicrosoftGraphAuthenticatorError.serverDeclinedScopes? = MicrosoftGraphAuthenticator.convertLoginFlowError(NSError(domain: MSALErrorDomain, code: MSALError.serverDeclinedScopes.rawValue)) as? MicrosoftGraphAuthenticatorError else {
			return XCTFail("Declined scopes aren't converted")
		}
		guard case MicrosoftGraphAuthenticatorError.missingAccountIdentifier? = MicrosoftGraphAuthenticator.convertLoginFlowError(nil) as? MicrosoftGraphAuthenticatorError else {
			return XCTFail("A login without an account and without an error isn't converted")
		}
	}
}
