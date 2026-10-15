//
//  DropboxAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccess
import XCTest
#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif

@MainActor
class DropboxAuthenticatorTests: XCTestCase {
	func testAuthenticateWithCancellationWhileWaitingForRedirect() async {
		DropboxSetup.constants = DropboxSetup(appKey: "", sharedContainerIdentifier: "", keychainService: "", forceForegroundSession: true)
		let authenticator = DropboxAuthenticator()
		let viewController = UIViewController()
		let authentication = Task {
			try await authenticator.authenticate(from: viewController)
		}
		// Lets the authentication run on the main actor until it waits for the redirect.
		await Task.yield()
		authentication.cancel()
		await XCTAssertThrowsErrorAsync(try await value(of: authentication)) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}
}
