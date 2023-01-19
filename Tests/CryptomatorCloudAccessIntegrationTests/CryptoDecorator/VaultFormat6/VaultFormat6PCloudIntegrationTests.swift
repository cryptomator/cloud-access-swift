//
//  VaultFormat6PCloudIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 14.03.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import PCloudSDKSwift
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
@testable import Promises

class VaultFormat6PCloudIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat6PCloudIntegrationTests.self)
	}

	private static let credential = PCloudCredentialMock()
	private static let client = PCloud.createClient(with: credential.user)
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! PCloudCloudProvider(client: client)
	private static let vaultPath = CloudPath("/iOS-IntegrationTests-VaultFormat6")

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/")
		let setUpPromise = cloudProvider.deleteFolderIfExisting(at: vaultPath).then {
			DecoratorFactory.createNewVaultFormat6(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
		}.then { decorator in
			setUpProvider = decorator
		}
		guard waitForPromises(timeout: 60.0) else {
			classSetUpError = IntegrationTestError.oneTimeSetUpTimeout
			return
		}
		if let error = setUpPromise.error {
			classSetUpError = error
			return
		}
		super.setUp()
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat6(delegate: VaultFormat6PCloudIntegrationTests.cloudProvider, vaultPath: VaultFormat6PCloudIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
			self.provider = decorator
		}
		guard waitForPromises(timeout: 60.0) else {
			if let error = setUpPromise.error {
				throw error
			}
			throw IntegrationTestError.setUpTimeout
		}
	}

	override func testFetchItemListPagination() throws {
		throw XCTSkip("pCloud does not support pagination")
	}
}
