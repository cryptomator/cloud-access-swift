//
//  NetworkConnectionErrorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.03.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct NetworkConnectionErrorTests {
		// MARK: - URLError codes that should be detected

		@Test
		func testNotConnectedToInternet() {
			let error = URLError(.notConnectedToInternet)
			#expect(isNetworkConnectionError(error))
		}

		@Test
		func testNetworkConnectionLost() {
			let error = URLError(.networkConnectionLost)
			#expect(isNetworkConnectionError(error))
		}

		@Test
		func testCannotFindHost() {
			let error = URLError(.cannotFindHost)
			#expect(isNetworkConnectionError(error))
		}

		@Test
		func testCannotConnectToHost() {
			let error = URLError(.cannotConnectToHost)
			#expect(isNetworkConnectionError(error))
		}

		@Test
		func dnsLookupFailed() {
			let error = URLError(.dnsLookupFailed)
			#expect(isNetworkConnectionError(error))
		}

		@Test
		func testInternationalRoamingOff() {
			let error = URLError(.internationalRoamingOff)
			#expect(isNetworkConnectionError(error))
		}

		@Test
		func testDataNotAllowed() {
			let error = URLError(.dataNotAllowed)
			#expect(isNetworkConnectionError(error))
		}

		// MARK: - URLError codes that should NOT be detected

		@Test
		func testTimedOut() {
			let error = URLError(.timedOut)
			#expect(!isNetworkConnectionError(error))
		}

		@Test
		func testBadURL() {
			let error = URLError(.badURL)
			#expect(!isNetworkConnectionError(error))
		}

		@Test
		func testBadServerResponse() {
			let error = URLError(.badServerResponse)
			#expect(!isNetworkConnectionError(error))
		}

		// MARK: - NSError with NSURLErrorDomain

		@Test
		func nsErrorWithNotConnectedToInternet() {
			let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
			#expect(isNetworkConnectionError(error))
		}

		@Test
		func nsErrorWithNetworkConnectionLost() {
			let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
			#expect(isNetworkConnectionError(error))
		}

		@Test
		func nsErrorWithTimedOut() {
			let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
			#expect(!isNetworkConnectionError(error))
		}

		// MARK: - Wrapped errors (NSUnderlyingErrorKey)

		@Test
		func wrappedURLError() {
			let underlyingError = URLError(.notConnectedToInternet)
			let wrappedError = NSError(domain: "SomeSDKDomain", code: 42, userInfo: [NSUnderlyingErrorKey: underlyingError])
			#expect(isNetworkConnectionError(wrappedError))
		}

		@Test
		func doubleWrappedURLError() {
			let underlyingError = URLError(.cannotConnectToHost)
			let middleError = NSError(domain: "MiddleDomain", code: 1, userInfo: [NSUnderlyingErrorKey: underlyingError])
			let outerError = NSError(domain: "OuterDomain", code: 2, userInfo: [NSUnderlyingErrorKey: middleError])
			#expect(isNetworkConnectionError(outerError))
		}

		@Test
		func wrappedNonNetworkError() {
			let underlyingError = URLError(.badURL)
			let wrappedError = NSError(domain: "SomeSDKDomain", code: 42, userInfo: [NSUnderlyingErrorKey: underlyingError])
			#expect(!isNetworkConnectionError(wrappedError))
		}

		// MARK: - Non-URL errors

		@Test
		func nonURLError() {
			let error = NSError(domain: "com.example.test", code: 100)
			#expect(!isNetworkConnectionError(error))
		}

		@Test
		func cocoaError() {
			let error = CocoaError(.fileReadNoSuchFile)
			#expect(!isNetworkConnectionError(error))
		}
	}
}
