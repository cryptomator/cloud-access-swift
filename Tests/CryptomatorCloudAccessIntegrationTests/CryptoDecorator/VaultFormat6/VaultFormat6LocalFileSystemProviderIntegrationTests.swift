//
//  VaultFormat6LocalFileSystemIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 06.11.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
@testable import Promises

class VaultFormat6LocalFileSystemIntegrationTests: CloudAccessIntegrationTest {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat6LocalFileSystemIntegrationTests.self)
	}

	private static let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
	private static let cloudProvider = LocalFileSystemProvider(rootURL: rootURL)
	private static let vaultPath = CloudPath("/iOS-IntegrationTests-VaultFormat6")

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/")
		do {
			try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
		} catch {
			classSetUpError = error
			return
		}
		let setUpPromise = DecoratorFactory.createNewVaultFormat6(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest").then { decorator in
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

	override class func tearDown() {
		super.tearDown()
		try? FileManager.default.removeItem(at: rootURL)
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		let cloudProvider = LocalFileSystemProvider(rootURL: VaultFormat6LocalFileSystemIntegrationTests.rootURL)
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat6(delegate: cloudProvider, vaultPath: VaultFormat6LocalFileSystemIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
			self.provider = decorator
		}
		guard waitForPromises(timeout: 60.0) else {
			if let error = setUpPromise.error {
				throw error
			}
			throw IntegrationTestError.setUpTimeout
		}
	}
}
