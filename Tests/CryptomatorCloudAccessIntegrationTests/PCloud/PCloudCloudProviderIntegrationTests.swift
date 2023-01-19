//
//  PCloudCloudProviderIntegrationTests.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 04.03.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import PCloudSDKSwift
import Promises
import XCTest

class PCloudCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: PCloudCloudProviderIntegrationTests.self)
	}

	private let credential = PCloudCredentialMock()

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain")
		let credential = PCloudCredentialMock()
		let client = PCloud.createClient(with: credential.user)
		// swiftlint:disable:next force_try
		setUpProvider = try! PCloudCloudProvider(client: client)
		super.setUp()
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		let client = PCloud.createClient(with: credential.user)
		provider = try PCloudCloudProvider(client: client)
	}

	override func deauthenticate() -> Promise<Void> {
		let invalidCredential = PCloudInvalidCredentialMock()
		let client = PCloud.createClient(with: invalidCredential.user)
		// swiftlint:disable:next force_try
		provider = try! PCloudCloudProvider(client: client)
		return Promise(())
	}

	override func testFetchItemListPagination() throws {
		throw XCTSkip("pCloud does not support pagination")
	}
}
