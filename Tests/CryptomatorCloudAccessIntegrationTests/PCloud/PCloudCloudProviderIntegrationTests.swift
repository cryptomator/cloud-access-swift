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
import XCTest
@testable import Promises

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
		guard classSetUpError == nil else { return }
		// Wait for pCloud's eventual consistency to catch up after setUp uploaded all test fixtures.
		let expectedItemCount = 6 // 5 files (test 0-4.txt) + 1 folder (testFolder)
		_ = waitForConsistency(provider: setUpProvider, folderPath: integrationTestRootCloudPath, expectedItemCount: expectedItemCount)
		guard waitForPromises(timeout: 60.0) else {
			classSetUpError = IntegrationTestError.oneTimeSetUpTimeout
			return
		}
	}

	private static func waitForConsistency(provider: CloudProvider, folderPath: CloudPath, expectedItemCount: Int, attempt: Int = 0) -> Promise<Void> {
		return provider.fetchItemList(forFolderAt: folderPath, withPageToken: nil).then { itemList -> Promise<Void> in
			if itemList.items.count >= expectedItemCount || attempt >= 10 {
				return Promise(())
			}
			return Promise(()).delay(1.0).then {
				return waitForConsistency(provider: provider, folderPath: folderPath, expectedItemCount: expectedItemCount, attempt: attempt + 1)
			}
		}
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
