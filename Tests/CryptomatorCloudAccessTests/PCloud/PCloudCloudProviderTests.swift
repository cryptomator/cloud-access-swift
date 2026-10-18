//
//  PCloudCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
@preconcurrency @testable import PCloudSDKSwift
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class PCloudCloudProviderTests: XCTestCase {
	let cancellationError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
	let networkConnectionError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

	func testThrowsCancellationErrorInCancelledTask() async throws {
		let client = PCloud.createClient(with: OAuth.User(id: 0, token: "", serverRegionId: 0, httpAPIHostName: "api.pcloud.com"))
		let provider = try PCloudCloudProvider(client: client)
		await assertThrowsCancellationErrorInCancelledTask(provider)
	}

	func testConvertCallError() {
		XCTAssertTrue(convertCallError(CallError<PCloudAPI.Stat.Error>.clientError(cancellationError)) is CancellationError)
		XCTAssertTrue(convertCallError(CallError<PCloudAPI.Stat.Error>.clientError(NSError(domain: "Test", code: 0, userInfo: [NSUnderlyingErrorKey: cancellationError]))) is CancellationError)
		XCTAssertEqual(.noInternetConnection, convertCallError(CallError<PCloudAPI.Stat.Error>.clientError(networkConnectionError)) as? CloudProviderError)
		XCTAssertEqual(.unauthorized, convertCallError(CallError<PCloudAPI.Stat.Error>.authError(.logInFailed)) as? CloudProviderError)
		XCTAssertEqual(.unauthorized, convertCallError(CallError<PCloudAPI.Stat.Error>.otherAPIError(0, nil)) as? CloudProviderError)
		guard case CallError<PCloudAPI.Stat.Error>.methodError(.fileDoesNotExist) = convertCallError(CallError<PCloudAPI.Stat.Error>.methodError(.fileDoesNotExist)) else {
			XCTFail("Expected the method error to be returned unchanged")
			return
		}
	}

	func testConvertNetworkOperationError() {
		XCTAssertTrue(convertNetworkOperationError(.clientError(cancellationError)) is CancellationError)
		XCTAssertEqual(.noInternetConnection, convertNetworkOperationError(.clientError(networkConnectionError)) as? CloudProviderError)
		guard case NetworkOperationError.protocolError = convertNetworkOperationError(.protocolError(cancellationError)) else {
			XCTFail("Expected the protocol error to be returned unchanged")
			return
		}
	}
}
