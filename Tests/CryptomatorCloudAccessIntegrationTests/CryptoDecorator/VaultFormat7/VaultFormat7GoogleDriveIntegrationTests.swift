//
//  VaultFormat7GoogleDriveIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 22.12.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultFormat7GoogleDriveIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat7GoogleDriveIntegrationTests.self)
	}

	private static let credential = GoogleDriveAuthenticatorMock.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: "IntegrationTest")
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! GoogleDriveCloudProvider(credential: credential)
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
		let credential = GoogleDriveAuthenticatorMock.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: UUID().uuidString)
		let cloudProvider = try GoogleDriveCloudProvider(credential: credential)
		provider = try await DecoratorFactory.createFromExistingVaultFormat7(delegate: cloudProvider, vaultPath: VaultFormat7GoogleDriveIntegrationTests.vaultPath, password: "IntegrationTest")
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		let credential = GoogleDriveAuthenticatorMock.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: UUID().uuidString)
		let limitedDelegate = try GoogleDriveCloudProvider(credential: credential,
		                                                   maxPageSize: maxPageSizeForLimitedCloudProvider)
		return try await DecoratorFactory.createFromExistingVaultFormat7(delegate: limitedDelegate, vaultPath: VaultFormat7GoogleDriveIntegrationTests.vaultPath, password: "IntegrationTest")
	}
}
