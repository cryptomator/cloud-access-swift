//
//  VaultFormat7MicrosoftGraphIntegrationTests.swift
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

class VaultFormat7MicrosoftGraphIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat7MicrosoftGraphIntegrationTests.self)
	}

	private static let credential = MicrosoftGraphCredentialMock()
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! MicrosoftGraphCloudProvider(credential: credential)
	private static let vaultPath = CloudPath("/iOS-IntegrationTests-VaultFormat7-\(runID)")

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/")
		do {
			setUpProvider = try blockingAwait(timeout: 60.0) {
				try await DecoratorFactory.createNewVaultFormat7(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
			}
		} catch {
			classSetUpError = error
			return
		}
		super.setUp()
	}

	override class func tearDown() {
		super.tearDown()
		try? blockingAwait(timeout: 60.0) {
			try await cloudProvider.deleteFolderIfExisting(at: vaultPath)
		}
	}

	override func setUp() async throws {
		try await super.setUp()
		provider = try await DecoratorFactory.createFromExistingVaultFormat7(delegate: VaultFormat7MicrosoftGraphIntegrationTests.cloudProvider, vaultPath: VaultFormat7MicrosoftGraphIntegrationTests.vaultPath, password: "IntegrationTest")
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		let limitedDelegate = try MicrosoftGraphCloudProvider(credential: VaultFormat7MicrosoftGraphIntegrationTests.credential,
		                                                      maxPageSize: maxPageSizeForLimitedCloudProvider)
		return try await DecoratorFactory.createFromExistingVaultFormat7(delegate: limitedDelegate, vaultPath: VaultFormat7MicrosoftGraphIntegrationTests.vaultPath, password: "IntegrationTest")
	}
}
