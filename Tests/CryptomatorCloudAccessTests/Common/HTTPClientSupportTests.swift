//
//  HTTPClientSupportTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessTestSupport
import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct HTTPClientSupportTests {
		@Test
		func retryDelayStaysWithinExponentialBound() {
			for _ in 0 ..< 100 {
				#expect((0 ... 1).contains(HTTPClientSupport.retryDelay(forRetry: 1)))
				#expect((0 ... 4).contains(HTTPClientSupport.retryDelay(forRetry: 3)))
			}
		}

		@Test
		func retryDelayOfResponse() throws {
			let now = try #require(Date.date(fromRFC822: "Tue, 20 Oct 2026 10:00:00 GMT"))
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
				#expect(.seconds(expectedSeconds) == HTTPClientSupport.retryDelay(for: httpResponse, attempt: 3, now: now), "\(retryAfter)")
			}
			for retryAfter in ["abc", "inf", "nan", nil] {
				let httpResponse = try response(retryAfter: retryAfter)
				let delay = HTTPClientSupport.retryDelay(for: httpResponse, attempt: 3, now: now)
				#expect((Duration.zero ... .seconds(4)).contains(delay), "\(retryAfter ?? "nil"): \(delay)")
			}
		}

		/// `SplitURLSession` records this error for a refused HTTPS→HTTP redirect, which a retry would only repeat.
		@Test
		func refusedDowngradeIsNotTransient() {
			#expect(!HTTPClientSupport.isTransient(URLError(.appTransportSecurityRequiresSecureConnection)))
		}

		@Test
		func hardenedConfigurationsCacheNothing() {
			for configuration in [HTTPClientSupport.hardened(.default), HTTPClientSupport.hardenedBackground(identifier: "test", sharedContainerIdentifier: nil)] {
				expectHardened(configuration)
			}
		}

		@Test
		func hardenedBackgroundConfiguration() {
			let configuration = HTTPClientSupport.hardenedBackground(identifier: "HTTPClientSupportTests", sharedContainerIdentifier: "group.test")

			#expect(configuration.identifier == "HTTPClientSupportTests")
			#expect(configuration.sharedContainerIdentifier == "group.test")
		}

		@Test
		func temporaryFileLiesInProcessFolder() throws {
			let url = try HTTPClientSupport.writeTemporaryFile { try $0.write(contentsOf: Data("hello".utf8)) }
			defer {
				removeItemRecordingFailure(at: url)
			}

			#expect(try ProcessTemporaryDirectory.shared.directoryURL().path == url.deletingLastPathComponent().path)
			#expect(try Data("hello".utf8) == Data(contentsOf: url))
		}

		/// A failure recorded while the task ran, e.g., an exceeded body limit, takes precedence over the cancellation it caused.
		@Test
		func httpResponseThrowsRecordedFailureBeforeTransportError() throws {
			let outcome = SplitURLSession.Outcome(response: nil, body: .none, error: URLError(.cancelled), recordedFailure: SplitURLSessionError.responseBodyTooLarge(limit: 1))

			let error = try #require(throws: (any Error).self) { try HTTPClientSupport.httpResponse(of: outcome) }
			guard case SplitURLSessionError.responseBodyTooLarge(limit: 1)? = error as? SplitURLSessionError else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		@Test
		func sanitizedErrorDropsFailingURLsOfNestedErrors() throws {
			let url = try #require(URL(string: "https://www.example.com/exampleBucket/file.txt?X-Amz-Signature=0123abcd"))
			let underlyingError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])
			let error = NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(CFNetworkErrors.cfErrorHTTPParseFailure.rawValue), userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString, NSURLErrorFailingURLPeerTrustErrorKey: "peer trust", NSUnderlyingErrorKey: underlyingError])

			let sanitizedError = HTTPClientSupport.sanitized(error) as NSError

			#expect((kCFErrorDomainCFNetwork as String) == sanitizedError.domain)
			#expect(Int(CFNetworkErrors.cfErrorHTTPParseFailure.rawValue) == sanitizedError.code)
			#expect(sanitizedError.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] == nil)
			#expect((sanitizedError.userInfo[NSUnderlyingErrorKey] as? URLError)?.code == .timedOut)
			#expect(!String(describing: sanitizedError).contains("0123abcd"), "\(sanitizedError)")
		}

		private func response(retryAfter: String?) throws -> HTTPURLResponse {
			let url = try #require(URL(string: "https://api.box.com/2.0/users/me"))
			return try #require(HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: retryAfter.map { ["Retry-After": $0] }))
		}
	}
}
