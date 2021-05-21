//
//  VaultFormat6DropboxIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 22.12.20.
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

class VaultFormat6DropboxIntegrationTests: CloudAccessIntegrationTest {
	static var setUpErrorForVaultFormat6Dropbox: Error?

	override class var classSetUpError: Error? {
		get {
			return setUpErrorForVaultFormat6Dropbox
		}
		set {
			setUpErrorForVaultFormat6Dropbox = newValue
		}
	}

	private static let setUpDropboxCredential = DropboxCredentialMock()
	private static let cloudProvider = DropboxCloudProvider(credential: setUpDropboxCredential)
	private static let vaultPath = CloudPath("/IntegrationTests-Vault6/")

	static var setUpProviderForVaultFormat6Dropbox: VaultFormat6ProviderDecorator?

	override class var setUpProvider: CloudProvider? {
		return setUpProviderForVaultFormat6Dropbox
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/")
	}

	override class func setUp() {
		let setUpPromise = cloudProvider.deleteFolderIfExisting(at: vaultPath).then {
			DecoratorFactory.createNewVaultFormat6(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
		}.then { decorator in
			setUpProviderForVaultFormat6Dropbox = decorator
		}.catch { error in
			print("VaultFormat6DropboxIntegrationTests setup error: \(error)")
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
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat6(delegate: cloudProvider, vaultPath: VaultFormat6DropboxIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
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
		return XCTestSuite(forTestCaseClass: VaultFormat6DropboxIntegrationTests.self)
	}
}
