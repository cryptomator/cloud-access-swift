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

	private static let cloudProvider = createSetUpOneDriveCloudProvider()
	private static let vaultPath = CloudPath("/IntegrationTests-Vault7/")

	static var setUpProviderForVaultFormat7OneDrive: VaultFormat7ProviderDecorator?

	class func createSetUpOneDriveCloudProvider() -> OneDriveCloudProvider {
		let oneDriveConfiguration = MSALPublicClientApplicationConfig(clientId: IntegrationTestSecrets.oneDriveClientId, redirectUri: IntegrationTestSecrets.oneDriveRedirectUri, authority: nil)
		oneDriveConfiguration.cacheConfig.keychainSharingGroup = Bundle.main.bundleIdentifier ?? ""
		let credential: OneDriveCredential
		let cloudProvider: OneDriveCloudProvider
		do {
			OneDriveSetup.clientApplication = try MSALPublicClientApplication(configuration: oneDriveConfiguration)
			let keychainItem = try OneDriveKeychainItem.getOneDriveAccountKeychainItem()
			let accountId = keychainItem.homeAccountId
			credential = try OneDriveCredential(with: accountId)
			cloudProvider = try OneDriveCloudProvider(credential: credential, useBackgroundSession: false)
		} catch {
			fatalError("Creation of setUp OneDriveCloudProvider failed with: \(error)")
		}
		return cloudProvider
	}

	override class var setUpProvider: CloudProvider? {
		return setUpProviderForVaultFormat7OneDrive
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/")
	}

	override class func setUp() {
		do {
			try OneDriveKeychainItem.fillKeychain()
		} catch {
			classSetUpError = error
			return
		}
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
		let expectation = XCTestExpectation()
		try super.setUpWithError()
		DecoratorFactory.createFromExistingVaultFormat7(delegate: VaultFormat7OneDriveIntegrationTests.cloudProvider, vaultPath: VaultFormat7OneDriveIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
			super.provider = decorator
		}.catch { error in
			XCTFail("Promise failed with error: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat7OneDriveIntegrationTests.self)
	}
}
