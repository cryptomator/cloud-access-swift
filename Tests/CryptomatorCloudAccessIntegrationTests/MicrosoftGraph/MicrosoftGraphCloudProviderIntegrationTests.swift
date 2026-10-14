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
import XCTest

class MicrosoftGraphCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: MicrosoftGraphCloudProviderIntegrationTests.self)
	}

	private static let credential = MicrosoftGraphCredentialMock() // Instantiate once because MicrosoftGraph doesn't like to get access token from refresh token frequently

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain-\(runID)")
		// swiftlint:disable:next force_try
		setUpProvider = try! MicrosoftGraphCloudProvider(credential: credential)
		super.setUp()
	}

	override func setUp() async throws {
		try await super.setUp()
		MicrosoftGraphCloudProviderIntegrationTests.credential.resetAccessTokenOverride()
		provider = try MicrosoftGraphCloudProvider(credential: MicrosoftGraphCloudProviderIntegrationTests.credential)
	}

	override func deauthenticate() async throws {
		try await MicrosoftGraphCloudProviderIntegrationTests.credential.deauthenticate()
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		return try MicrosoftGraphCloudProvider(credential: MicrosoftGraphCloudProviderIntegrationTests.credential,
		                                       maxPageSize: maxPageSizeForLimitedCloudProvider)
	}
}
