//
//  OneDriveCloudProviderIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 22.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Foundation
import Promises
import XCTest

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

	// swiftlint:disable:next force_try
	static let credential = try! OneDriveCredentialMock()
	// swiftlint:disable:next force_try
	static let setUpProviderForOneDrive = try! OneDriveCloudProvider(credential: credential, useBackgroundSession: false)

	override class var setUpProvider: CloudProvider {
		return setUpProviderForOneDrive
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/iOS-IntegrationTest/plain/")
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		super.provider = try OneDriveCloudProvider(credential: OneDriveCloudProviderIntegrationTests.credential, useBackgroundSession: false)
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: OneDriveCloudProviderIntegrationTests.self)
	}

	override func deauthenticate() -> Promise<Void> {
		// swiftlint:disable:next force_try
		let credential = try! OneDriveCredentialMock()
		try? credential.deauthenticate()
		// swiftlint:disable:next force_try
		super.provider = try! OneDriveCloudProvider(credential: credential, useBackgroundSession: false)
		return Promise(())
	}
}
