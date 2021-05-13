//
//  GoogleDriveCloudProviderIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 29.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Promises
import XCTest

class GoogleDriveCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	static var setUpErrorForGoogleDrive: Error?
	override class var classSetUpError: Error? {
		get {
			return setUpErrorForGoogleDrive
		}
		set {
			setUpErrorForGoogleDrive = newValue
		}
	}

	static let tokenUid = "IntegrationtTest"
	static let setUpGoogleDriveCredential = MockGoogleDriveAuthenticator.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: tokenUid)
	static var setUpProviderForGoogleDrive = GoogleDriveCloudProvider(credential: setUpGoogleDriveCredential, useBackgroundSession: false)

	override class var setUpProvider: CloudProvider {
		return setUpProviderForGoogleDrive
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/iOS-IntegrationTest/plain/")
	}

	private var credential: GoogleDriveCredential!

	override func setUpWithError() throws {
		try super.setUpWithError()
		credential = MockGoogleDriveAuthenticator.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: UUID().uuidString)
		super.provider = GoogleDriveCloudProvider(credential: credential, useBackgroundSession: false)
	}

	override func tearDown() {
		credential?.deauthenticate()
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: GoogleDriveCloudProviderIntegrationTests.self)
	}

	override func deauthenticate() -> Promise<Void> {
		credential.deauthenticate()
		return Promise(())
	}
}
