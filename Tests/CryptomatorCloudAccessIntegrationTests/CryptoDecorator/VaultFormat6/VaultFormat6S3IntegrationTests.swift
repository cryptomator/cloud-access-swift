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

class VaultFormat6S3IntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat6S3IntegrationTests.self)
	}

	// swiftlint:disable:next force_try
	private static let cloudProvider = try! S3CloudProvider(credential: IntegrationTestSecrets.s3Credential)
	private static let vaultPath = CloudPath("/iOS-IntegrationTests-VaultFormat6-\(runID)")

	override class func setUp() {
		S3CloudProviderIntegrationTests.onetimeAWSIntegrationTestsSetup

		integrationTestParentCloudPath = CloudPath("/")
		do {
			setUpProvider = try blockingAwait(timeout: 60.0) {
				try await DecoratorFactory.createNewVaultFormat6(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
			}
			// Wait for Scaleway S3's eventual consistency to catch up after vault creation.
			try blockingAwait(timeout: 60.0) {
				try await waitForVaultReadiness(rawProvider: cloudProvider, vaultPath: vaultPath)
			}
		} catch {
			classSetUpError = error
			return
		}
		super.setUp()
		guard classSetUpError == nil else { return }
		// Wait for Scaleway S3's eventual consistency to catch up after setUp uploaded all test fixtures.
		let expectedItemCount = 6 // 5 files (test 0-4.txt) + 1 folder (testFolder)
		waitForConsistencyOfSetUp(expectedItemCount: expectedItemCount)
	}

	override class func tearDown() {
		super.tearDown()
		try? blockingAwait(timeout: 60.0) {
			try await cloudProvider.deleteFolderIfExisting(at: vaultPath)
		}
	}

	override func setUp() async throws {
		try await super.setUp()
		provider = try await DecoratorFactory.createFromExistingVaultFormat6(delegate: VaultFormat6S3IntegrationTests.cloudProvider, vaultPath: VaultFormat6S3IntegrationTests.vaultPath, password: "IntegrationTest")
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		let limitedDelegate = try S3CloudProvider(credential: IntegrationTestSecrets.s3Credential, maxPageSize: maxPageSizeForLimitedCloudProvider)
		return try await DecoratorFactory.createFromExistingVaultFormat6(delegate: limitedDelegate, vaultPath: VaultFormat6S3IntegrationTests.vaultPath, password: "IntegrationTest")
	}
}
