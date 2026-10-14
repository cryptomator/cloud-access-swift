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
@preconcurrency import PCloudSDKSwift
import XCTest

class PCloudCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: PCloudCloudProviderIntegrationTests.self)
	}

	private let credential = PCloudCredentialMock()

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain-\(runID)")
		let credential = PCloudCredentialMock()
		let client = PCloud.createClient(with: credential.user)
		// swiftlint:disable:next force_try
		setUpProvider = try! PCloudCloudProvider(client: client)
		super.setUp()
		guard classSetUpError == nil else { return }
		// Wait for pCloud's eventual consistency to catch up after setUp uploaded all test fixtures.
		let expectedItemCount = 6 // 5 files (test 0-4.txt) + 1 folder (testFolder)
		waitForConsistencyOfSetUp(expectedItemCount: expectedItemCount)
	}

	override func setUp() async throws {
		try await super.setUp()
		let client = PCloud.createClient(with: credential.user)
		provider = try PCloudCloudProvider(client: client)
	}

	override func deauthenticate() async throws {
		let invalidCredential = PCloudInvalidCredentialMock()
		let client = PCloud.createClient(with: invalidCredential.user)
		provider = try PCloudCloudProvider(client: client)
	}

	override func testFetchItemListPagination() async throws {
		throw XCTSkip("pCloud does not support pagination")
	}
}
