//
//  VaultFormat7OneDriveIntegrationTests.swift
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
class VaultFormat7OneDriveIntegrationTests: CloudAccessIntegrationTest {
	static var setUpErrorForVaultFormat7OneDrive: Error?

	override class var classSetUpError: Error? {
		get {
			return setUpErrorForVaultFormat7OneDrive
		}
		set {
			setUpErrorForVaultFormat7OneDrive = newValue
		}
	}

	// swiftlint:disable:next force_try
	private static let setUpOneDriveCredential = try! OneDriveCredentialMock()
	// swiftlint:disable:next force_try
	private static let cloudProvider = try! OneDriveCloudProvider(credential: setUpOneDriveCredential, useBackgroundSession: false)
	private static let vaultPath = CloudPath("/IntegrationTests-Vault7/")

	static var setUpProviderForVaultFormat7OneDrive: VaultFormat7ProviderDecorator?

	override class var setUpProvider: CloudProvider? {
		return setUpProviderForVaultFormat7OneDrive
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/")
	}

	override class func setUp() {
		let setUpPromise = cloudProvider.deleteFolderIfExisting(at: vaultPath).then {
			DecoratorFactory.createNewVaultFormat7(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
		}.then { decorator in
			setUpProviderForVaultFormat7OneDrive = decorator
		}.catch { error in
			print("VaultFormat7OneDriveIntegrationTests setup error: \(error)")
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
		let setUpPromise = DecoratorFactory.createFromExistingVaultFormat7(delegate: VaultFormat7OneDriveIntegrationTests.cloudProvider, vaultPath: VaultFormat7OneDriveIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
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
		return XCTestSuite(forTestCaseClass: VaultFormat7OneDriveIntegrationTests.self)
	}
}
