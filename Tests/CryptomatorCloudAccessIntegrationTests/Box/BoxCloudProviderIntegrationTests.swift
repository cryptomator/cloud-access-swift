//
//  BoxCloudProviderIntegrationTests.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import XCTest

class BoxCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: BoxCloudProviderIntegrationTests.self)
	}

	private let credential = BoxCredentialMock()

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain-\(runID)")
		let credential = BoxCredentialMock()
		// swiftlint:disable:next force_try
		setUpProvider = try! BoxCloudProvider(credential: credential)
		super.setUp()
	}

	override func setUp() async throws {
		try await super.setUp()
		provider = try BoxCloudProvider(credential: credential)
	}

	override func deauthenticate() async throws {
		let invalidCredential = BoxInvalidCredentialMock()
		provider = try BoxCloudProvider(credential: invalidCredential)
	}

	override func createLimitedCloudProvider() async throws -> CloudProvider {
		return try BoxCloudProvider(credential: credential, maxPageSize: maxPageSizeForLimitedCloudProvider)
	}
}
