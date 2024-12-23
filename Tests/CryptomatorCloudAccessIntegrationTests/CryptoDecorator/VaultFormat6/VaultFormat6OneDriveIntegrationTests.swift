//
//  VaultFormat6MicrosoftGraphIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 04.05.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
@testable import Promises

class VaultFormat6MicrosoftGraphIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat6MicrosoftGraphIntegrationTests.self)
	}

	// swiftlint:disable:next force_try
	private static let credential = try! MicrosoftGraphCredentialMock()
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! MicrosoftGraphCloudProvider(credential: credential)
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
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat6(delegate: VaultFormat6MicrosoftGraphIntegrationTests.cloudProvider, vaultPath: VaultFormat6MicrosoftGraphIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
			self.provider = decorator
		}
		guard waitForPromises(timeout: 60.0) else {
			if let error = setUpPromise.error {
				throw error
			}
			throw IntegrationTestError.setUpTimeout
		}
	}

	override func createLimitedCloudProvider() throws -> CloudProvider {
		let limitedDelegate = try MicrosoftGraphCloudProvider(credential: VaultFormat6MicrosoftGraphIntegrationTests.credential,
		                                                maxPageSize: maxPageSizeForLimitedCloudProvider)
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat6(delegate: limitedDelegate, vaultPath: VaultFormat6MicrosoftGraphIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
			self.provider = decorator
		}
		guard waitForPromises(timeout: 60.0) else {
			if let error = setUpPromise.error {
				throw error
			}
			throw IntegrationTestError.setUpTimeout
		}
		return try XCTUnwrap(setUpPromise.value)
	}
}
