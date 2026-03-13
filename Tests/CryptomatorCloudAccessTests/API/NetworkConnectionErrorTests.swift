//
//  NetworkConnectionErrorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.03.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class NetworkConnectionErrorTests: XCTestCase {
	// MARK: - URLError codes that should be detected

	func testNotConnectedToInternet() {
		let error = URLError(.notConnectedToInternet)
		XCTAssertTrue(isNetworkConnectionError(error))
	}

	func testNetworkConnectionLost() {
		let error = URLError(.networkConnectionLost)
		XCTAssertTrue(isNetworkConnectionError(error))
	}

	func testCannotFindHost() {
		let error = URLError(.cannotFindHost)
		XCTAssertTrue(isNetworkConnectionError(error))
	}

	func testCannotConnectToHost() {
		let error = URLError(.cannotConnectToHost)
		XCTAssertTrue(isNetworkConnectionError(error))
	}

	func testDNSLookupFailed() {
		let error = URLError(.dnsLookupFailed)
		XCTAssertTrue(isNetworkConnectionError(error))
	}

	func testInternationalRoamingOff() {
		let error = URLError(.internationalRoamingOff)
		XCTAssertTrue(isNetworkConnectionError(error))
	}

	func testDataNotAllowed() {
		let error = URLError(.dataNotAllowed)
		XCTAssertTrue(isNetworkConnectionError(error))
	}

	// MARK: - URLError codes that should NOT be detected

	func testTimedOut() {
		let error = URLError(.timedOut)
		XCTAssertFalse(isNetworkConnectionError(error))
	}

	func testBadURL() {
		let error = URLError(.badURL)
		XCTAssertFalse(isNetworkConnectionError(error))
	}

	func testBadServerResponse() {
		let error = URLError(.badServerResponse)
		XCTAssertFalse(isNetworkConnectionError(error))
	}

	// MARK: - NSError with NSURLErrorDomain

	func testNSErrorWithNotConnectedToInternet() {
		let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
		XCTAssertTrue(isNetworkConnectionError(error))
	}

	func testNSErrorWithNetworkConnectionLost() {
		let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
		XCTAssertTrue(isNetworkConnectionError(error))
	}

	func testNSErrorWithTimedOut() {
		let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
		XCTAssertFalse(isNetworkConnectionError(error))
	}

	// MARK: - Wrapped errors (NSUnderlyingErrorKey)

	func testWrappedURLError() {
		let underlyingError = URLError(.notConnectedToInternet)
		let wrappedError = NSError(domain: "SomeSDKDomain", code: 42, userInfo: [NSUnderlyingErrorKey: underlyingError])
		XCTAssertTrue(isNetworkConnectionError(wrappedError))
	}

	func testDoubleWrappedURLError() {
		let underlyingError = URLError(.cannotConnectToHost)
		let middleError = NSError(domain: "MiddleDomain", code: 1, userInfo: [NSUnderlyingErrorKey: underlyingError])
		let outerError = NSError(domain: "OuterDomain", code: 2, userInfo: [NSUnderlyingErrorKey: middleError])
		XCTAssertTrue(isNetworkConnectionError(outerError))
	}

	func testWrappedNonNetworkError() {
		let underlyingError = URLError(.badURL)
		let wrappedError = NSError(domain: "SomeSDKDomain", code: 42, userInfo: [NSUnderlyingErrorKey: underlyingError])
		XCTAssertFalse(isNetworkConnectionError(wrappedError))
	}

	// MARK: - Non-URL errors

	func testNonURLError() {
		let error = NSError(domain: "com.example.test", code: 100)
		XCTAssertFalse(isNetworkConnectionError(error))
	}

	func testCocoaError() {
		let error = CocoaError(.fileReadNoSuchFile)
		XCTAssertFalse(isNetworkConnectionError(error))
	}
}
