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
import Promises
import XCTest

class BoxCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
    override class var defaultTestSuite: XCTestSuite {
        return XCTestSuite(forTestCaseClass: BoxCloudProviderIntegrationTests.self)
    }

    private let credential = BoxCredential()

    override class func setUp() {
        integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain")
        let credential = BoxCredential()
        // swiftlint:disable:next force_try
        setUpProvider = try! BoxCloudProvider(credential: credential)
        super.setUp()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        provider = try BoxCloudProvider(credential: credential)
    }

    override func deauthenticate() -> Promise<Void> {
        return Promise(())
    }

    override func createLimitedCloudProvider() throws -> CloudProvider {
        return try BoxCloudProvider(credential: credential)
    }
}
