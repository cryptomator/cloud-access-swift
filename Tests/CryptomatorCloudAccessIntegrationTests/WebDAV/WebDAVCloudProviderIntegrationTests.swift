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
import XCTest

class WebDAVCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	static let client = WebDAVClient(credential: IntegrationTestSecrets.webDAVCredential)

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: WebDAVCloudProviderIntegrationTests.self)
	}

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain-\(runID)")
		setUpProvider = try? WebDAVProvider(with: client)
		super.setUp()
	}

	override func setUp() async throws {
		try await super.setUp()
		let client = WebDAVCloudProviderIntegrationTests.client
		provider = try WebDAVProvider(with: client)
	}

	override func deauthenticate() async throws {
		let correctCredential = IntegrationTestSecrets.webDAVCredential
		let invalidCredential = WebDAVCredential(baseURL: correctCredential.baseURL, username: correctCredential.username, password: correctCredential.password + "Foo", allowedCertificate: correctCredential.allowedCertificate)
		let client = WebDAVClient(credential: invalidCredential)
		provider = try WebDAVProvider(with: client)
	}

	func testTLSCertificateValidatorReturnsServerCertificate() async throws {
		let baseURL = IntegrationTestSecrets.webDAVCredential.baseURL
		try XCTSkipUnless(baseURL.scheme == "https", "The WebDAV server is not reached via TLS")
		let certificate = try await TLSCertificateValidator(baseURL: baseURL).validate()
		XCTAssertFalse(certificate.data.isEmpty)
		XCTAssertEqual(32, certificate.fingerprint.split(separator: " ").count)
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		return try WebDAVProvider(with: WebDAVCloudProviderIntegrationTests.client, maxPageSize: maxPageSizeForLimitedCloudProvider)
	}
}
