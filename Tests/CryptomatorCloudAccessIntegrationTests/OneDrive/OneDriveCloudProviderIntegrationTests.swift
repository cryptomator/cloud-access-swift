//
//  OneDriveCloudProviderIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 22.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Promises
import XCTest

class OneDriveCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: OneDriveCloudProviderIntegrationTests.self)
	}

	// swiftlint:disable:next force_try
	private static let credential = try! OneDriveCredentialMock() // Instantiate once because OneDrive doesn't like to get access token from refresh token frequently

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain")
		// swiftlint:disable:next force_try
		setUpProvider = try! OneDriveCloudProvider(credential: credential, useBackgroundSession: false)
		super.setUp()
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		OneDriveCloudProviderIntegrationTests.credential.resetAccessTokenOverride()
		provider = try OneDriveCloudProvider(credential: OneDriveCloudProviderIntegrationTests.credential, useBackgroundSession: false)
	}

	override func deauthenticate() -> Promise<Void> {
		do {
			try OneDriveCloudProviderIntegrationTests.credential.deauthenticate()
			return Promise(())
		} catch {
			return Promise(error)
		}
	}

	override func createLimitedCloudProvider() throws -> CloudProvider {
		return try OneDriveCloudProvider(credential: OneDriveCloudProviderIntegrationTests.credential,
		                                 useBackgroundSession: false,
		                                 maxPageSize: maxPageSizeForLimitedCloudProvider)
	}
}
