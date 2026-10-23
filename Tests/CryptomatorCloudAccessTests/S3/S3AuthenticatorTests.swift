//
//  S3AuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 23.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// The buckets pass the name rule of virtual-hosted style, so that their requests are virtual-hosted unless path style is forced.
class S3AuthenticatorTests: XCTestCase {
	private typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)

	private static let awsCredential = S3Credential(accessKey: "access", secretKey: "secret", url: URL(string: "https://s3.us-east-1.amazonaws.com")!, bucket: "examplebucket", region: "us-east-1")
	private static let customCredential = S3Credential(accessKey: "access", secretKey: "secret", url: URL(string: "https://s3.example.com")!, bucket: "examplebucket", region: "us-east-1")

	override func tearDown() {
		URLProtocolMock.requestHandler = []
	}

	func testReturnsEqualCredentialWithoutCorrection() async throws {
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [S3AuthenticatorTests.listing(requests)]

		let credential = try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)

		XCTAssertEqual(S3AuthenticatorTests.customCredential, credential)
		XCTAssertEqual(["examplebucket.s3.example.com"], requests.requests.map { $0.url?.host })
	}

	// MARK: - Region

	/// AWS answers with a 301 that names the region only in the `x-amz-bucket-region` header, without a `Location`.
	func testCorrectsRegionAndAWSHostAfterPermanentRedirect() async throws {
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.permanentRedirect(toRegion: "eu-central-1", requests),
			S3AuthenticatorTests.listing(requests)
		]

		let credential = try await S3AuthenticatorTests.verify(S3AuthenticatorTests.awsCredential)

		XCTAssertEqual(try S3Credential(accessKey: "access", secretKey: "secret", url: XCTUnwrap(URL(string: "https://s3.eu-central-1.amazonaws.com")), bucket: "examplebucket", region: "eu-central-1", identifier: S3AuthenticatorTests.awsCredential.identifier), credential)
		XCTAssertEqual(["examplebucket.s3.us-east-1.amazonaws.com", "examplebucket.s3.eu-central-1.amazonaws.com"], requests.requests.map { $0.url?.host })
		XCTAssertEqual(["us-east-1", "eu-central-1"], requests.requests.map(S3AuthenticatorTests.signingRegion(of:)))
	}

	/// The 301 names the region that the request was signed with, but the host is of another region.
	func testMovesAWSHostOfOtherRegion() async throws {
		let requests = RequestRecorder()
		let input = S3Credential(accessKey: "access", secretKey: "secret", url: S3AuthenticatorTests.awsCredential.url, bucket: "examplebucket", region: "eu-central-1")
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.permanentRedirect(toRegion: "eu-central-1", requests),
			S3AuthenticatorTests.listing(requests)
		]

		let credential = try await S3AuthenticatorTests.verify(input)

		XCTAssertEqual("https://s3.eu-central-1.amazonaws.com", credential.url.absoluteString)
		XCTAssertEqual("eu-central-1", credential.region)
		XCTAssertEqual(["examplebucket.s3.us-east-1.amazonaws.com", "examplebucket.s3.eu-central-1.amazonaws.com"], requests.requests.map { $0.url?.host })
	}

	func testCorrectsOnlyRegionOfCustomHost() async throws {
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1", requests),
			S3AuthenticatorTests.listing(requests)
		]

		let credential = try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)

		XCTAssertEqual(S3AuthenticatorTests.customCredential.url, credential.url)
		XCTAssertEqual("eu-west-1", credential.region)
		XCTAssertEqual(S3AuthenticatorTests.customCredential.identifier, credential.identifier)
		XCTAssertEqual(["examplebucket.s3.example.com", "examplebucket.s3.example.com"], requests.requests.map { $0.url?.host })
		XCTAssertEqual(["us-east-1", "eu-west-1"], requests.requests.map(S3AuthenticatorTests.signingRegion(of:)))
	}

	func testWrongSecretBehindWrongRegionThrowsUnauthorized() async throws {
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1"),
			S3AuthenticatorTests.signatureDoesNotMatch()
		]

		await XCTAssertThrowsErrorAsync(try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
	}

	func testCorrectsRegionOnlyOnce() async throws {
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1"),
			S3AuthenticatorTests.permanentRedirect(toRegion: "eu-central-1"),
			S3AuthenticatorTests.listing()
		]

		await XCTAssertThrowsErrorAsync(try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)) { error in
			XCTAssertEqual("PermanentRedirect", (error as? S3Error)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testDoesNotCorrectToInvalidRegion() async throws {
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1/x"),
			S3AuthenticatorTests.listing()
		]

		await XCTAssertThrowsErrorAsync(try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)) { error in
			XCTAssertEqual("AuthorizationHeaderMalformed", (error as? S3Error)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	/// A stored credential may carry a region alias of AWS SDK 2.41.0, which signs like the region it names.
	func testDoesNotRetryCorrectionEqualToCredential() async throws {
		let input = S3AuthenticatorTests.customCredential
		for region in ["us-east-1", "USEast1"] {
			URLProtocolMock.requestHandler = [
				S3AuthenticatorTests.authorizationHeaderMalformed(region: "us-east-1"),
				S3AuthenticatorTests.listing()
			]

			await XCTAssertThrowsErrorAsync(try await S3AuthenticatorTests.verify(S3Credential(accessKey: input.accessKey, secretKey: input.secretKey, url: input.url, bucket: input.bucket, region: region)), region) { error in
				XCTAssertEqual("AuthorizationHeaderMalformed", (error as? S3Error)?.code, region)
			}
			XCTAssertEqual(1, URLProtocolMock.requestHandler.count, region)
		}
	}

	// MARK: - Path Style

	func testFallsBackToPathStyleAfterTLSFailure() async throws {
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.failure(.serverCertificateUntrusted, requests),
			S3AuthenticatorTests.listing(requests)
		]

		let credential = try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)

		let input = S3AuthenticatorTests.customCredential
		XCTAssertEqual(S3Credential(accessKey: input.accessKey, secretKey: input.secretKey, url: input.url, bucket: input.bucket, region: input.region, forcePathStyle: true, identifier: input.identifier), credential)
		XCTAssertEqual(["https://examplebucket.s3.example.com/", "https://s3.example.com/examplebucket"], requests.requests.map { $0.url.map(S3AuthenticatorTests.urlWithoutQuery) })
	}

	/// The client retries a DNS failure three times before the fallback runs.
	func testFallsBackToPathStyleAfterRetriedDNSFailure() async throws {
		URLProtocolMock.requestHandler = Array(repeating: S3AuthenticatorTests.failure(.cannotFindHost), count: 4) + [S3AuthenticatorTests.listing()]

		let credential = try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)

		XCTAssertEqual(true, credential.forcePathStyle)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// A server that only serves virtual-hosted requests may answer a path-style one with 403, which says nothing about the cause.
	func testFailedPathStyleFallbackThrowsFailureThatTriggeredIt() async throws {
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.failure(.serverCertificateUntrusted),
			S3AuthenticatorTests.signatureDoesNotMatch()
		]

		await XCTAssertThrowsErrorAsync(try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)) { error in
			XCTAssertEqual(.serverCertificateUntrusted, (error as? URLError)?.code)
		}
	}

	/// A wrong-region error to the path-style request shows that the server took it, so the failure of the listing in the corrected region counts.
	func testCorrectsRegionAfterPathStyleFallback() async throws {
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.failure(.serverCertificateUntrusted, requests),
			S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1", requests),
			S3AuthenticatorTests.signatureDoesNotMatch(requests)
		]

		await XCTAssertThrowsErrorAsync(try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
		let sentRequests = requests.requests
		XCTAssertEqual(["https://examplebucket.s3.example.com/", "https://s3.example.com/examplebucket", "https://s3.example.com/examplebucket"], sentRequests.map { $0.url.map(S3AuthenticatorTests.urlWithoutQuery) })
		XCTAssertEqual(["us-east-1", "us-east-1", "eu-west-1"], sentRequests.map(S3AuthenticatorTests.signingRegion(of:)))
	}

	func testPathStyleFallbackThrowsWrongRegionErrorWithoutValidRegion() async throws {
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.failure(.serverCertificateUntrusted),
			S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1/x"),
			S3AuthenticatorTests.listing()
		]

		await XCTAssertThrowsErrorAsync(try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)) { error in
			XCTAssertEqual("AuthorizationHeaderMalformed", (error as? S3Error)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	/// A connection failure that isn't about the bucket's host, e.g., a timeout, says nothing about the addressing, and forced path style would be stored with the credential.
	func testDoesNotFallBackAfterOtherConnectionFailure() async throws {
		URLProtocolMock.requestHandler = Array(repeating: S3AuthenticatorTests.failure(.timedOut), count: 4) + [S3AuthenticatorTests.listing()]

		await XCTAssertThrowsErrorAsync(try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)) { error in
			XCTAssertEqual(.timedOut, (error as? URLError)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testDoesNotFallBackAfterUnauthorized() async throws {
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.signatureDoesNotMatch(),
			S3AuthenticatorTests.listing()
		]

		await XCTAssertThrowsErrorAsync(try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testDoesNotFallBackWithForcedPathStyle() async throws {
		let input = S3AuthenticatorTests.customCredential
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.failure(.serverCertificateUntrusted),
			S3AuthenticatorTests.listing()
		]

		await XCTAssertThrowsErrorAsync(try await S3AuthenticatorTests.verify(S3Credential(accessKey: input.accessKey, secretKey: input.secretKey, url: input.url, bucket: input.bucket, region: input.region, forcePathStyle: true))) { error in
			XCTAssertEqual(.serverCertificateUntrusted, (error as? URLError)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	// MARK: - Cancellation

	func testThrowsCancellationErrorInCancelledTaskWithoutRequest() async throws {
		URLProtocolMock.requestHandler = [S3AuthenticatorTests.listing()]

		await XCTAssertThrowsErrorAsync(try await value(of: cancelledTask {
			try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	/// The client doesn't check for cancellation before it throws a failure that it doesn't retry, so only the check before a further listing stops the correction.
	func testDoesNotCorrectAfterCancellationDuringFirstListing() async throws {
		let triggers: [(name: String, response: Handler)] = [
			("TLS failure", S3AuthenticatorTests.failure(.serverCertificateUntrusted)),
			("wrong region", S3AuthenticatorTests.permanentRedirect(toRegion: "eu-central-1"))
		]
		for (name, response) in triggers {
			let canceller = TaskCanceller<S3Credential>()
			URLProtocolMock.requestHandler = [
				{ request in
					canceller.cancel()
					return try response(request)
				},
				S3AuthenticatorTests.listing()
			]

			await XCTAssertThrowsErrorAsync(try await value(of: canceller.start {
				try await S3AuthenticatorTests.verify(S3AuthenticatorTests.awsCredential)
			}), name) { error in
				XCTAssertTrue(error is CancellationError, "\(name): unexpected error: \(error)")
			}
			XCTAssertEqual(1, URLProtocolMock.requestHandler.count, name)
		}
	}

	func testThrowsCancellationErrorAfterCancellationDuringPathStyleListing() async throws {
		let canceller = TaskCanceller<S3Credential>()
		let signatureDoesNotMatch = S3AuthenticatorTests.signatureDoesNotMatch()
		URLProtocolMock.requestHandler = [
			S3AuthenticatorTests.failure(.serverCertificateUntrusted),
			{ request in
				canceller.cancel()
				return try signatureDoesNotMatch(request)
			}
		]

		await XCTAssertThrowsErrorAsync(try await value(of: canceller.start {
			try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
	}

	// MARK: - Helpers

	private static func verify(_ credential: S3Credential) async throws -> S3Credential {
		return try await S3Authenticator.verifyCredential(credential, makeClient: { try S3Client.mocked(credential: $0) })
	}

	private static func listing(_ requests: RequestRecorder = RequestRecorder()) -> Handler {
		return URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []), onRequest: requests.record)
	}

	private static func permanentRedirect(toRegion region: String, _ requests: RequestRecorder = RequestRecorder()) -> Handler {
		let body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>PermanentRedirect</Code><Message>The bucket you are attempting to access must be addressed using the specified endpoint. Please send all future requests to this endpoint.</Message><Endpoint>examplebucket.s3.\(region).amazonaws.com</Endpoint><Bucket>examplebucket</Bucket></Error>"
		return URLProtocolMock.handler(statusCode: 301, body: body, headerFields: ["x-amz-bucket-region": region], onRequest: requests.record)
	}

	private static func authorizationHeaderMalformed(region: String, _ requests: RequestRecorder = RequestRecorder()) -> Handler {
		let body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>AuthorizationHeaderMalformed</Code><Message>The authorization header is malformed; the region is wrong.</Message><Region>\(region)</Region></Error>"
		return URLProtocolMock.handler(statusCode: 400, body: body, onRequest: requests.record)
	}

	private static func signatureDoesNotMatch(_ requests: RequestRecorder = RequestRecorder()) -> Handler {
		return URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>SignatureDoesNotMatch</Code></Error>", onRequest: requests.record)
	}

	private static func failure(_ code: URLError.Code, _ requests: RequestRecorder = RequestRecorder()) -> Handler {
		return { request in
			requests.record(request)
			throw URLError(code)
		}
	}

	/// Returns the region of the `Authorization` header's scope, e.g., `eu-central-1` of `Credential=access/20261023/eu-central-1/s3/aws4_request`.
	private static func signingRegion(of request: URLRequest) -> String? {
		return request.value(forHTTPHeaderField: "Authorization")?.split(separator: "/").dropFirst(2).first.map(String.init)
	}

	private static func urlWithoutQuery(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		components?.query = nil
		return components?.string ?? ""
	}
}
