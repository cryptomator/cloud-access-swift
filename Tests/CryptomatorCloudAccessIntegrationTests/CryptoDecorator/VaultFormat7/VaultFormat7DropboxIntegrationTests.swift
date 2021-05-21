//
//  VaultFormat7DropboxIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 18.11.20.
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

class VaultFormat7DropboxIntegrationTests: CloudAccessIntegrationTest {
	static var setUpErrorForVaultFormat7Dropbox: Error?

	override class var classSetUpError: Error? {
		get {
			return setUpErrorForVaultFormat7Dropbox
		}
		set {
			setUpErrorForVaultFormat7Dropbox = newValue
		}
	}

	private static let setUpDropboxCredential = DropboxCredentialMock()
	private static let cloudProvider = DropboxCloudProvider(credential: setUpDropboxCredential)
	private static let vaultPath = CloudPath("/IntegrationTests-Vault7/")

	static var setUpProviderForVaultFormat7Dropbox: VaultFormat7ProviderDecorator?

	override class var setUpProvider: CloudProvider? {
		return setUpProviderForVaultFormat7Dropbox
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/")
	}

	override class func setUp() {
		let setUpPromise = cloudProvider.deleteFolderIfExisting(at: vaultPath).then {
			DecoratorFactory.createNewVaultFormat7(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
		}.then { decorator in
			setUpProviderForVaultFormat7Dropbox = decorator
		}.catch { error in
			print("VaultFormat7DropboxIntegrationTests setup error: \(error)")
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
		let credential = DropboxCredentialMock()
		let cloudProvider = DropboxCloudProvider(credential: credential)
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat7(delegate: cloudProvider, vaultPath: VaultFormat7DropboxIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
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
		return XCTestSuite(forTestCaseClass: VaultFormat7DropboxIntegrationTests.self)
	}
}
