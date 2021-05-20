//
//  VaultFormat6OneDriveIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 04.05.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import Foundation
import XCTest
@testable import MSAL
@testable import Promises
class VaultFormat6OneDriveIntegrationTests: CloudAccessIntegrationTest {
	static var setUpErrorForVaultFormat6OneDrive: Error?

	override class var classSetUpError: Error? {
		get {
			return setUpErrorForVaultFormat6OneDrive
		}
		set {
			setUpErrorForVaultFormat6OneDrive = newValue
		}
	}

	// swiftlint:disable:next force_try
	private static let setUpOneDriveCredential = try! OneDriveCredentialMock()
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! OneDriveCloudProvider(credential: setUpOneDriveCredential, useBackgroundSession: false)
	private static let vaultPath = CloudPath("/IntegrationTests-Vault6/")

	static var setUpProviderForVaultFormat6OneDrive: VaultFormat6ProviderDecorator?

	override class var setUpProvider: CloudProvider? {
		return setUpProviderForVaultFormat6OneDrive
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/")
	}

	override class func setUp() {
		let setUpPromise = cloudProvider.deleteFolderIfExisting(at: vaultPath).then {
			DecoratorFactory.createNewVaultFormat6(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
		}.then { decorator in
			setUpProviderForVaultFormat6OneDrive = decorator
		}.catch { error in
			print("VaultFormat6OneDriveIntegrationTests setup error: \(error)")
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
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat6(delegate: VaultFormat6OneDriveIntegrationTests.cloudProvider, vaultPath: VaultFormat6OneDriveIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
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
		return XCTestSuite(forTestCaseClass: VaultFormat6OneDriveIntegrationTests.self)
	}
}
