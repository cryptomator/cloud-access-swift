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

	func testRetryDelayOfResponse() throws {
		let now = try XCTUnwrap(Date.date(fromRFC822: "Tue, 20 Oct 2026 10:00:00 GMT"))
		let exactCases: [(String, Double)] = [
			("7", 7),
			(" 7 ", 7),
			("Tue, 20 Oct 2026 10:00:30 GMT", 30),
			("Tue, 20 Oct 2026 09:00:00 GMT", 0),
			("3600", 60),
			("1e30", 60)
		]
		for (retryAfter, expectedSeconds) in exactCases {
			let httpResponse = try response(retryAfter: retryAfter)
			XCTAssertEqual(.seconds(expectedSeconds), HTTPClientSupport.retryDelay(for: httpResponse, attempt: 3, now: now), retryAfter)
		}
		for retryAfter in ["abc", "inf", "nan", nil] {
			let httpResponse = try response(retryAfter: retryAfter)
			let delay = HTTPClientSupport.retryDelay(for: httpResponse, attempt: 3, now: now)
			XCTAssertTrue((Duration.zero ... .seconds(4)).contains(delay), "\(retryAfter ?? "nil"): \(delay)")
		}
	}

	func testHardenedConfigurationsCacheNothing() {
		for configuration in [HTTPClientSupport.hardened(.default), HTTPClientSupport.hardenedBackground(identifier: "test", sharedContainerIdentifier: nil)] {
			XCTAssertNil(configuration.urlCache)
			XCTAssertNil(configuration.urlCredentialStorage)
			XCTAssertNotNil(configuration.httpCookieStorage)
			XCTAssertFalse(configuration.httpCookieStorage === HTTPCookieStorage.shared)
		}
	}

	func testHardenedBackgroundConfiguration() {
		let configuration = HTTPClientSupport.hardenedBackground(identifier: "HTTPClientSupportTests", sharedContainerIdentifier: "group.test")

		XCTAssertEqual("HTTPClientSupportTests", configuration.identifier)
		XCTAssertEqual("group.test", configuration.sharedContainerIdentifier)
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

	private func response(retryAfter: String?) throws -> HTTPURLResponse {
		return try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(URL(string: "https://api.box.com/2.0/users/me")), statusCode: 503, httpVersion: "HTTP/1.1", headerFields: retryAfter.map { ["Retry-After": $0] }))
	}
}
