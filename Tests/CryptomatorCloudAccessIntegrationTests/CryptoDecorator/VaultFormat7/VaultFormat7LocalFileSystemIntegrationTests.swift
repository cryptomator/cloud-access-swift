//
//  VaultFormat7LocalFileSystemIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 23.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultFormat7LocalFileSystemIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat7LocalFileSystemIntegrationTests.self)
	}

	private static let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! LocalFileSystemProvider(rootURL: rootURL)
	private static let vaultPath = CloudPath("/iOS-IntegrationTests-VaultFormat7")

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/")
		do {
			try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
		} catch {
			classSetUpError = error
			return
		}
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
		try? FileManager.default.removeItem(at: rootURL)
	}

	override func setUp() async throws {
		try await super.setUp()
		let cloudProvider = try LocalFileSystemProvider(rootURL: VaultFormat7LocalFileSystemIntegrationTests.rootURL)
		provider = try await DecoratorFactory.createFromExistingVaultFormat7(delegate: cloudProvider, vaultPath: VaultFormat7LocalFileSystemIntegrationTests.vaultPath, password: "IntegrationTest")
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		let cloudProvider = try LocalFileSystemProvider(rootURL: VaultFormat7LocalFileSystemIntegrationTests.rootURL,
		                                                maxPageSize: maxPageSizeForLimitedCloudProvider)
		return try await DecoratorFactory.createFromExistingVaultFormat7(delegate: cloudProvider, vaultPath: VaultFormat7LocalFileSystemIntegrationTests.vaultPath, password: "IntegrationTest")
	}
}
