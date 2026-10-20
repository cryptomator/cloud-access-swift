//
//  HTTPClientSupportTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class HTTPClientSupportTests: XCTestCase {
	func testRetryDelayStaysWithinExponentialBound() {
		for _ in 0 ..< 100 {
			XCTAssertTrue((0 ... 1).contains(HTTPClientSupport.retryDelay(forRetry: 1)))
			XCTAssertTrue((0 ... 4).contains(HTTPClientSupport.retryDelay(forRetry: 3)))
		}
	}

	func testHardenedConfigurationsCacheNothing() {
		for configuration in [HTTPClientSupport.hardened(.default), HTTPClientSupport.hardened(.background(withIdentifier: "test"))] {
			XCTAssertNil(configuration.urlCache)
			XCTAssertNil(configuration.urlCredentialStorage)
			XCTAssertNotNil(configuration.httpCookieStorage)
			XCTAssertFalse(configuration.httpCookieStorage === HTTPCookieStorage.shared)
		}
	}

	/// A failure recorded while the task ran, e.g., an exceeded body limit, takes precedence over the cancellation it caused.
	func testHTTPResponseThrowsRecordedFailureBeforeTransportError() {
		let outcome = SplitURLSession.Outcome(response: nil, body: .none, error: URLError(.cancelled), recordedFailure: SplitURLSessionError.responseBodyTooLarge(limit: 1))

		XCTAssertThrowsError(try HTTPClientSupport.httpResponse(of: outcome)) { error in
			guard case SplitURLSessionError.responseBodyTooLarge(limit: 1)? = error as? SplitURLSessionError else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testSanitizedErrorDropsFailingURLsOfNestedErrors() throws {
		let url = try XCTUnwrap(URL(string: "https://www.example.com/exampleBucket/file.txt?X-Amz-Signature=0123abcd"))
		let underlyingError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])
		let error = NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(CFNetworkErrors.cfErrorHTTPParseFailure.rawValue), userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString, NSUnderlyingErrorKey: underlyingError])

		let sanitizedError = HTTPClientSupport.sanitized(error) as NSError

		XCTAssertEqual(kCFErrorDomainCFNetwork as String, sanitizedError.domain)
		XCTAssertEqual(Int(CFNetworkErrors.cfErrorHTTPParseFailure.rawValue), sanitizedError.code)
		XCTAssertEqual(.timedOut, (sanitizedError.userInfo[NSUnderlyingErrorKey] as? URLError)?.code)
		XCTAssertFalse(String(describing: sanitizedError).contains("0123abcd"), "\(sanitizedError)")
	}
}
