//
//  VaultFormat6S3IntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 21.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
@testable import Promises

class VaultFormat6S3IntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat6S3IntegrationTests.self)
	}

	// swiftlint:disable:next force_try
	private static let cloudProvider = try! S3CloudProvider(credential: IntegrationTestSecrets.s3Credential)
	private static let vaultPath = CloudPath("/iOS-IntegrationTests-VaultFormat6")

	override class func setUp() {
		S3CloudProviderIntegrationTests.onetimeAWSIntegrationTestsSetup

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
		// Wait for Scaleway S3's eventual consistency to catch up after vault creation.
		_ = waitForVaultReadiness()
		guard waitForPromises(timeout: 60.0) else {
			classSetUpError = IntegrationTestError.oneTimeSetUpTimeout
			return
		}
		super.setUp()
		guard classSetUpError == nil else { return }
		// Wait for Scaleway S3's eventual consistency to catch up after setUp uploaded all test fixtures.
		let expectedItemCount = 6 // 5 files (test 0-4.txt) + 1 folder (testFolder)
		_ = waitForConsistency(provider: setUpProvider, folderPath: integrationTestRootCloudPath, expectedItemCount: expectedItemCount)
		guard waitForPromises(timeout: 60.0) else {
			classSetUpError = IntegrationTestError.oneTimeSetUpTimeout
			return
		}
	}

	/// Waits for the vault's `d/` directory structure to become visible on S3.
	/// Uses the raw S3 provider (not the vault decorator) to avoid partial-state issues
	/// where the vault decorator's `createFolder` is not idempotent on retry.
	private static func waitForVaultReadiness(attempt: Int = 0) -> Promise<Void> {
		let dFolderPath = vaultPath.appendingPathComponent("d")
		return cloudProvider.fetchItemList(forFolderAt: dFolderPath, withPageToken: nil).then { itemList -> Promise<Void> in
			guard !itemList.items.isEmpty else {
				if attempt >= 30 {
					return Promise(IntegrationTestError.consistencyTimeout)
				}
				return Promise(()).delay(2.0).then {
					return waitForVaultReadiness(attempt: attempt + 1)
				}
			}
			return Promise(())
		}.recover { error -> Promise<Void> in
			if attempt >= 30 {
				return Promise(error)
			}
			return Promise(()).delay(2.0).then {
				return waitForVaultReadiness(attempt: attempt + 1)
			}
		}
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat6(delegate: VaultFormat6S3IntegrationTests.cloudProvider, vaultPath: VaultFormat6S3IntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
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
		let limitedDelegate = try S3CloudProvider(credential: IntegrationTestSecrets.s3Credential, maxPageSize: maxPageSizeForLimitedCloudProvider)
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat6(delegate: limitedDelegate, vaultPath: VaultFormat6S3IntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
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
