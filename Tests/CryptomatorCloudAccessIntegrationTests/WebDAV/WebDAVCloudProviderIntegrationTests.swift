//
//  WebDAVCloudProviderIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 12.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Foundation
import Promises
import XCTest

class WebDAVCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	static var setUpErrorForWebDAV: Error?

	override class var classSetUpError: Error? {
		get {
			return setUpErrorForWebDAV
		}
		set {
			setUpErrorForWebDAV = newValue
		}
	}

	static let setUpClientForWebDAV = WebDAVClient(credential: IntegrationTestSecrets.webDAVCredential, sharedContainerIdentifier: "CryptomatorConstants.appGroupName", useBackgroundSession: false)
	static let setUpProviderForWebDAV = WebDAVProvider(with: setUpClientForWebDAV)

	override class var setUpProvider: CloudProvider {
		return setUpProviderForWebDAV
	}

	override class var integrationTestParentCloudPath: CloudPath {
		return CloudPath("/iOSIntegrationTests/")
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		let client = WebDAVCloudProviderIntegrationTests.setUpClientForWebDAV
		super.provider = WebDAVProvider(with: client)
	}

	override func deauthenticate() -> Promise<Void> {
		let correctCredential = IntegrationTestSecrets.webDAVCredential
		let invalidCredential = WebDAVCredential(baseURL: correctCredential.baseURL, username: correctCredential.username, password: correctCredential.password + "Foo", allowedCertificate: correctCredential.allowedCertificate)
		let client = WebDAVClient(credential: invalidCredential, sharedContainerIdentifier: "CryptomatorConstants.appGroupName", useBackgroundSession: false)
		super.provider = WebDAVProvider(with: client)
		return Promise(())
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: WebDAVCloudProviderIntegrationTests.self)
	}
}
