//
//  VaultFormat7LocalFileSystemProviderIntegrationTests.swift
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
@testable import CryptomatorCryptoLib
@testable import Promises

class VaultFormat7LocalFileSystemIntegrationTests: CloudAccessIntegrationTest {
	static var setUpErrorForVaultFormat7LocalFileSystem: Error?
	override class var classSetUpError: Error? {
		get {
			return setUpErrorForVaultFormat7LocalFileSystem
		}
		set {
			setUpErrorForVaultFormat7LocalFileSystem = newValue
		}
	}

	private static let cloudProvider = LocalFileSystemProvider(rootURL: URL(fileURLWithPath: "/"))
	private static let vaultPath = CloudPath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).path + "/")

	static var setUpProviderForVaultFormat7LocalFileSystem: VaultFormat7ProviderDecorator?

	override class var setUpProvider: CloudProvider? {
		return setUpProviderForVaultFormat7LocalFileSystem
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/")
	}

	override class func setUp() {
		let setUpPromise = DecoratorFactory.createNewVaultFormat7(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest").then { decorator in
			setUpProviderForVaultFormat7LocalFileSystem = decorator
		}.catch { error in
			print("VaultFormat7LocalFileSystemIntegrationTests setup error: \(error)")
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

	override func setUpWithError() throws {
		let expectation = XCTestExpectation()
		try super.setUpWithError()
		try FileManager.default.createDirectory(atPath: VaultFormat7LocalFileSystemIntegrationTests.vaultPath.path, withIntermediateDirectories: true, attributes: nil)
		let cloudProvider = LocalFileSystemProvider(rootURL: URL(fileURLWithPath: "/"))
		DecoratorFactory.createFromExistingVaultFormat7(delegate: cloudProvider, vaultPath: VaultFormat7LocalFileSystemIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
			super.provider = decorator
		}.catch { error in
			XCTFail("Promise failed with error: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat7LocalFileSystemIntegrationTests.self)
	}
}
