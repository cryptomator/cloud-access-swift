//
//  VaultFormat7GoogleDriveIntegrationTests.swift
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

class VaultFormat7GoogleDriveIntegrationTests: CloudAccessIntegrationTest {
	static var setUpErrorForVaultFormat7GoogleDrive: Error?

	override class var classSetUpError: Error? {
		get {
			return setUpErrorForVaultFormat7GoogleDrive
		}
		set {
			setUpErrorForVaultFormat7GoogleDrive = newValue
		}
	}

	static let tokenUID = "IntegrationtTest"
	private static let setUpGoogleDriveCredential = MockGoogleDriveAuthenticator.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: tokenUID)
	private static let cloudProvider = GoogleDriveCloudProvider(credential: setUpGoogleDriveCredential, useBackgroundSession: false)
	private static let vaultPath = CloudPath("/IntegrationTests-Vault7/")

	static var setUpProviderForVaultFormat7GoogleDrive: VaultFormat7ProviderDecorator?

	override class var setUpProvider: CloudProvider? {
		return setUpProviderForVaultFormat7GoogleDrive
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/")
	}

	private var credential: GoogleDriveCredential!

	override class func setUp() {
		let setUpPromise = cloudProvider.deleteFolderIfExisting(at: vaultPath).then {
			DecoratorFactory.createNewVaultFormat7(delegate: cloudProvider, vaultPath: vaultPath, password: "IntegrationTest")
		}.then { decorator in
			setUpProviderForVaultFormat7GoogleDrive = decorator
		}.catch { error in
			print("VaultFormat7GoogleDriveIntegrationTests setup error: \(error)")
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
		let credential = MockGoogleDriveAuthenticator.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: UUID().uuidString)
		let cloudProvider = GoogleDriveCloudProvider(credential: credential, useBackgroundSession: false)
		DecoratorFactory.createFromExistingVaultFormat7(delegate: cloudProvider, vaultPath: VaultFormat7GoogleDriveIntegrationTests.vaultPath, password: "IntegrationTest").then { decorator in
			super.provider = decorator
		}.catch { error in
			XCTFail("Promise failed with error: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	override func tearDown() {
		credential?.deauthenticate()
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: VaultFormat7GoogleDriveIntegrationTests.self)
	}
}
