//
//  OneDriveCloudProviderIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 22.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccess
import Foundation
import Promises
import XCTest
@testable import MSAL
class OneDriveCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	static var setUpErrorForOneDrive: Error?
	override class var classSetUpError: Error? {
		get {
			return setUpErrorForOneDrive
		}
		set {
			setUpErrorForOneDrive = newValue
		}
	}

	static let setUpProviderForOneDrive = createSetUpOneDriveCloudProvider()

	override class var setUpProvider: CloudProvider {
		return setUpProviderForOneDrive
	}

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

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/iOS-IntegrationTest/plain/")
	}

	override class func setUp() {
		do {
			try OneDriveKeychainItem.fillKeychain()
		} catch {
			classSetUpError = error
			return
		}
		super.setUp()
	}

	private var credential: OneDriveCredential!

	override func setUpWithError() throws {
		try super.setUpWithError()
		let keychainItem = try OneDriveKeychainItem.getOneDriveAccountKeychainItem()
		let accountId = keychainItem.homeAccountId
		let credential = try OneDriveCredential(with: accountId)
		self.credential = credential
		super.provider = try OneDriveCloudProvider(credential: credential, useBackgroundSession: false)
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: OneDriveCloudProviderIntegrationTests.self)
	}

	override func deauthenticate() -> Promise<Void> {
		do {
			credential = try OneDriveCredential(with: "InvalidIdentifier")
			super.provider = try OneDriveCloudProvider(credential: credential, useBackgroundSession: false)
		} catch {
			return Promise(error)
		}
		return Promise(())
	}
}
