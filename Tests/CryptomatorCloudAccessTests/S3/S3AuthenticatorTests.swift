//
//  S3AuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 23.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessTestSupport
import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

private typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)

extension UnitTests {
	/// The buckets pass the name rule of virtual-hosted style, so that their requests are virtual-hosted unless path style is forced.
	struct S3AuthenticatorTests {
		private static let awsCredential = S3Credential(accessKey: "access", secretKey: "secret", url: URL(string: "https://s3.us-east-1.amazonaws.com")!, bucket: "examplebucket", region: "us-east-1")
		private static let customCredential = S3Credential(accessKey: "access", secretKey: "secret", url: URL(string: "https://s3.example.com")!, bucket: "examplebucket", region: "us-east-1")

		init() {
			URLProtocolMock.requestHandler = []
		}

		@Test
		func returnsEqualCredentialWithoutCorrection() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [S3AuthenticatorTests.listing(requests)]

			let credential = try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)

			#expect(S3AuthenticatorTests.customCredential == credential)
			#expect(requests.requests.map { $0.url?.host } == ["examplebucket.s3.example.com"])
		}

		// MARK: - Region

		/// AWS answers with a 301 that names the region only in the `x-amz-bucket-region` header, without a `Location`.
		@Test
		func correctsRegionAndAWSHostAfterPermanentRedirect() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3AuthenticatorTests.permanentRedirect(toRegion: "eu-central-1", requests),
				S3AuthenticatorTests.listing(requests)
			]

			let credential = try await S3AuthenticatorTests.verify(S3AuthenticatorTests.awsCredential)

			#expect(try S3Credential(accessKey: "access", secretKey: "secret", url: #require(URL(string: "https://s3.eu-central-1.amazonaws.com")), bucket: "examplebucket", region: "eu-central-1", identifier: S3AuthenticatorTests.awsCredential.identifier) == credential)
			#expect(requests.requests.map { $0.url?.host } == ["examplebucket.s3.us-east-1.amazonaws.com", "examplebucket.s3.eu-central-1.amazonaws.com"])
			#expect(requests.requests.map(S3AuthenticatorTests.signingRegion(of:)) == ["us-east-1", "eu-central-1"])
		}

		/// The 301 names the region that the request was signed with, but the host is of another region.
		@Test
		func movesAWSHostOfOtherRegion() async throws {
			let requests = RequestRecorder()
			let input = S3Credential(accessKey: "access", secretKey: "secret", url: S3AuthenticatorTests.awsCredential.url, bucket: "examplebucket", region: "eu-central-1")
			URLProtocolMock.requestHandler = [
				S3AuthenticatorTests.permanentRedirect(toRegion: "eu-central-1", requests),
				S3AuthenticatorTests.listing(requests)
			]

			let credential = try await S3AuthenticatorTests.verify(input)

			#expect(credential.url.absoluteString == "https://s3.eu-central-1.amazonaws.com")
			#expect(credential.region == "eu-central-1")
			#expect(requests.requests.map { $0.url?.host } == ["examplebucket.s3.us-east-1.amazonaws.com", "examplebucket.s3.eu-central-1.amazonaws.com"])
		}

		@Test
		func correctsOnlyRegionOfCustomHost() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1", requests),
				S3AuthenticatorTests.listing(requests)
			]

			let credential = try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)

			#expect(S3AuthenticatorTests.customCredential.url == credential.url)
			#expect(credential.region == "eu-west-1")
			#expect(S3AuthenticatorTests.customCredential.identifier == credential.identifier)
			#expect(requests.requests.map { $0.url?.host } == ["examplebucket.s3.example.com", "examplebucket.s3.example.com"])
			#expect(requests.requests.map(S3AuthenticatorTests.signingRegion(of:)) == ["us-east-1", "eu-west-1"])
		}

		@Test
		func wrongSecretBehindWrongRegionThrowsUnauthorized() async throws {
			URLProtocolMock.requestHandler = [
				S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1"),
				S3AuthenticatorTests.signatureDoesNotMatch()
			]

			await #expect(throws: CloudProviderError.unauthorized) { try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential) }
		}

		@Test
		func correctsRegionOnlyOnce() async throws {
			URLProtocolMock.requestHandler = [
				S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1"),
				S3AuthenticatorTests.permanentRedirect(toRegion: "eu-central-1"),
				S3AuthenticatorTests.listing()
			]

			let error = try await #require(throws: (any Error).self) { try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential) }
			#expect((error as? S3Error)?.code == "PermanentRedirect")
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func doesNotCorrectToInvalidRegion() async throws {
			URLProtocolMock.requestHandler = [
				S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1/x"),
				S3AuthenticatorTests.listing()
			]

			let error = try await #require(throws: (any Error).self) { try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential) }
			#expect((error as? S3Error)?.code == "AuthorizationHeaderMalformed")
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		/// A stored credential may carry a region alias of AWS SDK 2.41.0, which signs like the region it names.
		@Test
		func doesNotRetryCorrectionEqualToCredential() async throws {
			let input = S3AuthenticatorTests.customCredential
			for region in ["us-east-1", "USEast1"] {
				URLProtocolMock.requestHandler = [
					S3AuthenticatorTests.authorizationHeaderMalformed(region: "us-east-1"),
					S3AuthenticatorTests.listing()
				]

				let error = try await #require(throws: (any Error).self, "\(region)") { try await S3AuthenticatorTests.verify(S3Credential(accessKey: input.accessKey, secretKey: input.secretKey, url: input.url, bucket: input.bucket, region: region)) }
				#expect((error as? S3Error)?.code == "AuthorizationHeaderMalformed", "\(region)")
				#expect(URLProtocolMock.requestHandler.count == 1, "\(region)")
			}
		}

		// MARK: - Path Style

		@Test
		func fallsBackToPathStyleAfterTLSFailure() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3MockResponse.failure(.serverCertificateUntrusted, requests),
				S3AuthenticatorTests.listing(requests)
			]

			let credential = try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)

			let input = S3AuthenticatorTests.customCredential
			#expect(S3Credential(accessKey: input.accessKey, secretKey: input.secretKey, url: input.url, bucket: input.bucket, region: input.region, forcePathStyle: true, identifier: input.identifier) == credential)
			#expect(requests.requests.map { $0.url.map(S3AuthenticatorTests.urlWithoutQuery) } == ["https://examplebucket.s3.example.com/", "https://s3.example.com/examplebucket"])
		}

		/// The client retries a DNS failure three times before the fallback runs.
		@Test
		func fallsBackToPathStyleAfterRetriedDNSFailure() async throws {
			URLProtocolMock.requestHandler = Array(repeating: S3MockResponse.failure(.cannotFindHost), count: 4) + [S3AuthenticatorTests.listing()]

			let credential = try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)

			#expect(credential.forcePathStyle == true)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A server that only serves virtual-hosted requests may answer a path-style one with 403, which says nothing about the cause.
		@Test
		func failedPathStyleFallbackThrowsFailureThatTriggeredIt() async throws {
			URLProtocolMock.requestHandler = [
				S3MockResponse.failure(.serverCertificateUntrusted),
				S3AuthenticatorTests.signatureDoesNotMatch()
			]

			let error = try await #require(throws: (any Error).self) { try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential) }
			#expect((error as? URLError)?.code == .serverCertificateUntrusted)
		}

		/// A wrong-region error to the path-style request shows that the server took it, so the failure of the listing in the corrected region counts.
		@Test
		func correctsRegionAfterPathStyleFallback() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3MockResponse.failure(.serverCertificateUntrusted, requests),
				S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1", requests),
				S3AuthenticatorTests.signatureDoesNotMatch(requests)
			]

			await #expect(throws: CloudProviderError.unauthorized) { try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential) }
			let sentRequests = requests.requests
			#expect(sentRequests.map { $0.url.map(S3AuthenticatorTests.urlWithoutQuery) } == ["https://examplebucket.s3.example.com/", "https://s3.example.com/examplebucket", "https://s3.example.com/examplebucket"])
			#expect(sentRequests.map(S3AuthenticatorTests.signingRegion(of:)) == ["us-east-1", "us-east-1", "eu-west-1"])
		}

		@Test
		func pathStyleFallbackThrowsWrongRegionErrorWithoutValidRegion() async throws {
			URLProtocolMock.requestHandler = [
				S3MockResponse.failure(.serverCertificateUntrusted),
				S3AuthenticatorTests.authorizationHeaderMalformed(region: "eu-west-1/x"),
				S3AuthenticatorTests.listing()
			]

			let error = try await #require(throws: (any Error).self) { try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential) }
			#expect((error as? S3Error)?.code == "AuthorizationHeaderMalformed")
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		/// A connection failure that isn't about the bucket's host, e.g., a timeout, says nothing about the addressing, and forced path style would be stored with the credential.
		@Test
		func doesNotFallBackAfterOtherConnectionFailure() async throws {
			URLProtocolMock.requestHandler = Array(repeating: S3MockResponse.failure(.timedOut), count: 4) + [S3AuthenticatorTests.listing()]

			let error = try await #require(throws: (any Error).self) { try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential) }
			#expect((error as? URLError)?.code == .timedOut)
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func doesNotFallBackAfterUnauthorized() async throws {
			URLProtocolMock.requestHandler = [
				S3AuthenticatorTests.signatureDoesNotMatch(),
				S3AuthenticatorTests.listing()
			]

			await #expect(throws: CloudProviderError.unauthorized) { try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func doesNotFallBackWithForcedPathStyle() async throws {
			let input = S3AuthenticatorTests.customCredential
			URLProtocolMock.requestHandler = [
				S3MockResponse.failure(.serverCertificateUntrusted),
				S3AuthenticatorTests.listing()
			]

			let error = try await #require(throws: (any Error).self) { try await S3AuthenticatorTests.verify(S3Credential(accessKey: input.accessKey, secretKey: input.secretKey, url: input.url, bucket: input.bucket, region: input.region, forcePathStyle: true)) }
			#expect((error as? URLError)?.code == .serverCertificateUntrusted)
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		// MARK: - Cancellation

		@Test
		func throwsCancellationErrorInCancelledTaskWithoutRequest() async throws {
			URLProtocolMock.requestHandler = [S3AuthenticatorTests.listing()]

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: cancelledTask {
					try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)
				})
			}
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		/// The client doesn't check for cancellation before it throws a failure that it doesn't retry, so only the check before a further listing stops the correction.
		@Test
		func doesNotCorrectAfterCancellationDuringFirstListing() async throws {
			let triggers: [(name: String, response: Handler)] = [
				("TLS failure", S3MockResponse.failure(.serverCertificateUntrusted)),
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

				await #expect(throws: CancellationError.self, "\(name)") {
					try await cancellingValue(of: canceller.start {
						try await S3AuthenticatorTests.verify(S3AuthenticatorTests.awsCredential)
					})
				}
				#expect(URLProtocolMock.requestHandler.count == 1, "\(name)")
			}
		}

		@Test
		func throwsCancellationErrorAfterCancellationDuringPathStyleListing() async throws {
			let canceller = TaskCanceller<S3Credential>()
			let signatureDoesNotMatch = S3AuthenticatorTests.signatureDoesNotMatch()
			URLProtocolMock.requestHandler = [
				S3MockResponse.failure(.serverCertificateUntrusted),
				{ request in
					canceller.cancel()
					return try signatureDoesNotMatch(request)
				}
			]

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: canceller.start {
					try await S3AuthenticatorTests.verify(S3AuthenticatorTests.customCredential)
				})
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
}
