//
//  VaultFormat6WebDAVIntegrationTests.swift
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

class VaultFormat6WebDAVIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat6WebDAVIntegrationTests.self)
	}

	private static let client = WebDAVClient(credential: IntegrationTestSecrets.webDAVCredential)
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! WebDAVProvider(with: client)
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
		provider = try await DecoratorFactory.createFromExistingVaultFormat6(delegate: VaultFormat6WebDAVIntegrationTests.cloudProvider, vaultPath: VaultFormat6WebDAVIntegrationTests.vaultPath, password: "IntegrationTest")
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		let limitedWebDAVCloudProvider = try WebDAVProvider(with: VaultFormat6WebDAVIntegrationTests.client,
		                                                    maxPageSize: maxPageSizeForLimitedCloudProvider)
		return try await DecoratorFactory.createFromExistingVaultFormat6(delegate: limitedWebDAVCloudProvider, vaultPath: VaultFormat6WebDAVIntegrationTests.vaultPath, password: "IntegrationTest")
	}
}
