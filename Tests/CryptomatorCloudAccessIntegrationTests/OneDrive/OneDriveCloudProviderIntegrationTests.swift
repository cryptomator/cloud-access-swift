//
//  MicrosoftGraphCloudProviderIntegrationTests.swift
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

class MicrosoftGraphCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: MicrosoftGraphCloudProviderIntegrationTests.self)
	}

	// swiftlint:disable:next force_try
	private static let credential = try! MicrosoftGraphCredentialMock() // Instantiate once because MicrosoftGraph doesn't like to get access token from refresh token frequently

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain")
		// swiftlint:disable:next force_try
		setUpProvider = try! MicrosoftGraphCloudProvider(credential: credential)
		super.setUp()
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		MicrosoftGraphCloudProviderIntegrationTests.credential.resetAccessTokenOverride()
		provider = try MicrosoftGraphCloudProvider(credential: MicrosoftGraphCloudProviderIntegrationTests.credential)
	}

	override func deauthenticate() -> Promise<Void> {
		do {
			try MicrosoftGraphCloudProviderIntegrationTests.credential.deauthenticate()
			return Promise(())
		} catch {
			return Promise(error)
		}
	}

	override func createLimitedCloudProvider() throws -> CloudProvider {
		return try MicrosoftGraphCloudProvider(credential: MicrosoftGraphCloudProviderIntegrationTests.credential,
		                                 maxPageSize: maxPageSizeForLimitedCloudProvider)
	}
}
