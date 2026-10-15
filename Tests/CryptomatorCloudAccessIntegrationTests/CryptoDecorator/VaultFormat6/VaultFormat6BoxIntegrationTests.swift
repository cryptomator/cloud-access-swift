//
//  VaultFormat6BoxIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Majid Achhoud on 29.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultFormat6BoxIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat6BoxIntegrationTests.self)
	}

	private static let credential = BoxCredentialMock()
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! BoxCloudProvider(credential: credential)
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
	}

	override class func tearDown() {
		super.tearDown()
		try? blockingAwait(timeout: 60.0) {
			try await cloudProvider.deleteFolderIfExisting(at: vaultPath)
		}
	}

	override func setUp() async throws {
		try await super.setUp()
		let credential = BoxCredentialMock()
		let cloudProvider = try BoxCloudProvider(credential: credential)
		provider = try await DecoratorFactory.createFromExistingVaultFormat6(delegate: cloudProvider, vaultPath: VaultFormat6BoxIntegrationTests.vaultPath, password: "IntegrationTest")
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		let credential = BoxCredentialMock()
		let limitedDelegate = try BoxCloudProvider(credential: credential, maxPageSize: maxPageSizeForLimitedCloudProvider)
		return try await DecoratorFactory.createFromExistingVaultFormat6(delegate: limitedDelegate, vaultPath: VaultFormat6BoxIntegrationTests.vaultPath, password: "IntegrationTest")
	}
}
