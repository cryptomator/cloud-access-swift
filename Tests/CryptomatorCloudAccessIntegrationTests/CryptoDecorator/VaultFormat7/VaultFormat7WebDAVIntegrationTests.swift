//
//  VaultFormat7WebDAVIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 19.12.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
@testable import Promises

class VaultFormat7WebDAVIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat7WebDAVIntegrationTests.self)
	}

	private static let client = WebDAVClient(credential: IntegrationTestSecrets.webDAVCredential)
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! WebDAVProvider(with: client)
	private static let vaultPath = CloudPath("/iOS-IntegrationTests-VaultFormat7")

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/")
		let setUpPromise = cloudProvider.deleteFolderIfExisting(at: vaultPath).then {
			DecoratorFactory.createNewVaultFormat7(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
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
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat7(delegate: VaultFormat7WebDAVIntegrationTests.cloudProvider, vaultPath: VaultFormat7WebDAVIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
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
		let limitedWebDAVCloudProvider = try WebDAVProvider(with: VaultFormat7WebDAVIntegrationTests.client, maxPageSize: maxPageSizeForLimitedCloudProvider)
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat7(delegate: limitedWebDAVCloudProvider, vaultPath: VaultFormat7WebDAVIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
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
