//
//  GoogleDriveCloudProviderIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 29.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Promises
import XCTest

class GoogleDriveCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: GoogleDriveCloudProviderIntegrationTests.self)
	}

	private var credential: GoogleDriveCredential!

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain")
		let credential = GoogleDriveAuthenticatorMock.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: "IntegrationTest")
		// swiftlint:disable:next force_try
		setUpProvider = try! GoogleDriveCloudProvider(credential: credential)
		super.setUp()
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		credential = GoogleDriveAuthenticatorMock.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: UUID().uuidString)
		provider = try GoogleDriveCloudProvider(credential: credential)
	}

	override func deauthenticate() -> Promise<Void> {
		credential.deauthenticate()
		return Promise(())
	}

	override func createLimitedCloudProvider() throws -> CloudProvider {
		return try GoogleDriveCloudProvider(credential: credential,
		                                    maxPageSize: maxPageSizeForLimitedCloudProvider)
	}
}
