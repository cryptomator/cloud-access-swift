//
//  VaultFormat6LocalFileSystemIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 06.11.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import XCTest
@testable import CryptomatorCryptoLib
@testable import Promises

class VaultFormat6LocalFileSystemIntegrationTests: CloudAccessIntegrationTest {
	static var setUpErrorForVaultFormat6LocalFileSystem: Error?
	override class var classSetUpError: Error? {
		get {
			return setUpErrorForVaultFormat6LocalFileSystem
		}
		set {
			setUpErrorForVaultFormat6LocalFileSystem = newValue
		}
	}

	private static let cloudProvider = LocalFileSystemProvider(rootURL: URL(fileURLWithPath: "/"))
	private static let vaultPath = CloudPath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).path + "/")

	static var setUpProviderForVaultFormat6LocalFileSystem: VaultFormat6ProviderDecorator?

	override class var setUpProvider: CloudProvider? {
		return setUpProviderForVaultFormat6LocalFileSystem
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/")
	}

	override class func setUp() {
		let setUpPromise = DecoratorFactory.createNewVaultFormat6(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest").then { decorator in
			setUpProviderForVaultFormat6LocalFileSystem = decorator
		}.catch { error in
			print("VaultFormat6LocalFileSystemIntegrationTests setup error: \(error)")
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
		try FileManager.default.createDirectory(atPath: VaultFormat6LocalFileSystemIntegrationTests.vaultPath.path, withIntermediateDirectories: true, attributes: nil)
		let cloudProvider = LocalFileSystemProvider(rootURL: URL(fileURLWithPath: "/"))
		DecoratorFactory.createFromExistingVaultFormat6(delegate: cloudProvider, vaultPath: VaultFormat6LocalFileSystemIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
			super.provider = decorator
		}.catch { error in
			XCTFail("Promise failed with error: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat6LocalFileSystemIntegrationTests.self)
	}
}
