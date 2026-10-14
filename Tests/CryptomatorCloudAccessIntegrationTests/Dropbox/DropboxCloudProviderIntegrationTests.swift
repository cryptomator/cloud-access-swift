//
//  DropboxCloudProviderIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 05.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import XCTest

class DropboxCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: DropboxCloudProviderIntegrationTests.self)
	}

	private let credential = DropboxCredentialMock()

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain-\(runID)")
		let credential = DropboxCredentialMock()
		setUpProvider = DropboxCloudProvider(credential: credential)
		super.setUp()
	}

	override func setUp() async throws {
		try await super.setUp()
		credential.setAuthorizedClient()
		provider = DropboxCloudProvider(credential: credential)
	}

	override func deauthenticate() async throws {
		credential.deauthenticate()
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		return DropboxCloudProvider(credential: credential, maxPageSize: maxPageSizeForLimitedCloudProvider)
	}
}
