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
import Promises
import XCTest

class WebDAVCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	static let client = WebDAVClient(credential: IntegrationTestSecrets.webDAVCredential)

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: WebDAVCloudProviderIntegrationTests.self)
	}

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain")
		setUpProvider = WebDAVProvider(with: client)
		super.setUp()
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		let client = WebDAVCloudProviderIntegrationTests.client
		provider = WebDAVProvider(with: client)
	}

	override func deauthenticate() -> Promise<Void> {
		let correctCredential = IntegrationTestSecrets.webDAVCredential
		let invalidCredential = WebDAVCredential(baseURL: correctCredential.baseURL, username: correctCredential.username, password: correctCredential.password + "Foo", allowedCertificate: correctCredential.allowedCertificate)
		let client = WebDAVClient(credential: invalidCredential)
		provider = WebDAVProvider(with: client)
		return Promise(())
	}
}
