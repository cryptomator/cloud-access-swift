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
import Promises
import XCTest

class DropboxCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: DropboxCloudProviderIntegrationTests.self)
	}

	private let credential = DropboxCredentialMock()

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain")
		let credential = DropboxCredentialMock()
		setUpProvider = DropboxCloudProvider(credential: credential)
		super.setUp()
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		credential.setAuthorizedClient()
		provider = DropboxCloudProvider(credential: credential)
	}

	override func deauthenticate() -> Promise<Void> {
		credential.deauthenticate()
		return Promise(())
	}

	override func createLimitedCloudProvider() throws -> CloudProvider {
		return DropboxCloudProvider(credential: credential, maxPageSize: maxPageSizeForLimitedCloudProvider)
	}
}
