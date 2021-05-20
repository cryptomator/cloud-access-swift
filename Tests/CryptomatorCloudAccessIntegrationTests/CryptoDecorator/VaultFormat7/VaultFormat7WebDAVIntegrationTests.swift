//
//  VaultFormat7WebDAVIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 19.12.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import Foundation
import XCTest
@testable import Promises

class VaultFormat7WebDAVIntegrationTests: CloudAccessIntegrationTest {
	static var setUpErrorForVaultFormat7WebDAV: Error?

	override class var classSetUpError: Error? {
		get {
			return setUpErrorForVaultFormat7WebDAV
		}
		set {
			setUpErrorForVaultFormat7WebDAV = newValue
		}
	}

	private static let setUpClientForWebDAV = WebDAVClient(credential: IntegrationTestSecrets.webDAVCredential)
	private static let cloudProvider = WebDAVProvider(with: setUpClientForWebDAV)
	private static let vaultPath = CloudPath("/IntegrationTests-Vault7/")

	static var setUpProviderForVaultFormat7WebDAV: VaultFormat7ProviderDecorator?

	override class var setUpProvider: CloudProvider? {
		return setUpProviderForVaultFormat7WebDAV
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/")
	}

	override class func setUp() {
		let setUpPromise = cloudProvider.deleteFolderIfExisting(at: vaultPath).then {
			DecoratorFactory.createNewVaultFormat7(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
		}.then { decorator in
			setUpProviderForVaultFormat7WebDAV = decorator
		}.catch { error in
			print("VaultFormat7WebDAVIntegrationTests setup error: \(error)")
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
		try super.setUpWithError()
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat7(delegate: VaultFormat7WebDAVIntegrationTests.cloudProvider, vaultPath: VaultFormat7WebDAVIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
			super.provider = decorator
		}
		guard waitForPromises(timeout: 60.0) else {
			if let error = setUpPromise.error {
				throw error
			}
			throw IntegrationTestError.setUpTimeout
		}
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat7WebDAVIntegrationTests.self)
	}
}
