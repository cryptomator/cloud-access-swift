//
//  VaultFormat7DropboxIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 18.11.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultFormat7DropboxIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat7DropboxIntegrationTests.self)
	}

	private static let credential = DropboxCredentialMock()
	private static let cloudProvider = DropboxCloudProvider(credential: credential)
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
		let credential = DropboxCredentialMock()
		let cloudProvider = DropboxCloudProvider(credential: credential)
		provider = try await DecoratorFactory.createFromExistingVaultFormat7(delegate: cloudProvider, vaultPath: VaultFormat7DropboxIntegrationTests.vaultPath, password: "IntegrationTest")
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		let credential = DropboxCredentialMock()
		let limitedDelegate = DropboxCloudProvider(credential: credential, maxPageSize: maxPageSizeForLimitedCloudProvider)
		return try await DecoratorFactory.createFromExistingVaultFormat7(delegate: limitedDelegate, vaultPath: VaultFormat7DropboxIntegrationTests.vaultPath, password: "IntegrationTest")
	}
}
