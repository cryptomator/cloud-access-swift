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

	private static let cloudProvider = createSetUpOneDriveCloudProvider()
	private static let vaultPath = CloudPath("/IntegrationTests-Vault6/")

	static var setUpProviderForVaultFormat6OneDrive: VaultFormat6ProviderDecorator?

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
		return setUpProviderForVaultFormat6OneDrive
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
		let expectation = XCTestExpectation()
		try super.setUpWithError()
		DecoratorFactory.createFromExistingVaultFormat6(delegate: VaultFormat6OneDriveIntegrationTests.cloudProvider, vaultPath: VaultFormat6OneDriveIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
			super.provider = decorator
		}.catch { error in
			XCTFail("Promise failed with error: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat6OneDriveIntegrationTests.self)
	}
}
