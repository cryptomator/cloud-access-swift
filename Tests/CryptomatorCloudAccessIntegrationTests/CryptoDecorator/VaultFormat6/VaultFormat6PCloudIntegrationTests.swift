//
//  VaultFormat6PCloudIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 14.03.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

@preconcurrency import PCloudSDKSwift
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultFormat6PCloudIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat6PCloudIntegrationTests.self)
	}

	private static let credential = PCloudCredentialMock()
	private static let client = PCloud.createClient(with: credential.user)
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! PCloudCloudProvider(client: client)
	private static let vaultPath = CloudPath("/iOS-IntegrationTests-VaultFormat6-\(runID)")

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/")
		do {
			setUpProvider = try blockingAwait(timeout: 60.0) {
				try await DecoratorFactory.createNewVaultFormat6(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
			}
		} catch {
			classSetUpError = error
			return
		}
		super.setUp()
		guard classSetUpError == nil else { return }
		// Wait for pCloud's eventual consistency to catch up after setUp uploaded all test fixtures.
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
		provider = try await DecoratorFactory.createFromExistingVaultFormat6(delegate: VaultFormat6PCloudIntegrationTests.cloudProvider, vaultPath: VaultFormat6PCloudIntegrationTests.vaultPath, password: "IntegrationTest")
	}

	override func testFetchItemListPagination() async throws {
		throw XCTSkip("pCloud does not support pagination")
	}
}
