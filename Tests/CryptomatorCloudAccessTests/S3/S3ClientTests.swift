//
//  S3ClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class S3ClientTests {
		private let sleeps: SleepRecorder
		private let client: S3Client
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.sleeps = SleepRecorder()
			self.client = try S3Client.mocked(sleeps: sleeps)
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		// MARK: - Signing

		@Test
		func requestsAreSigned() async throws {
			let headers = OSAllocatedUnfairLock(initialState: [String: String]())
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []), onRequest: { request in
				headers.withLock { $0 = request.allHTTPHeaderFields ?? [:] }
			})]

			_ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)

			let sentHeaders = headers.withLock { $0 }
			#expect(sentHeaders["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 Credential=access/") ?? false, "\(sentHeaders)")
			#expect(sentHeaders["x-amz-date"] != nil)
			#expect(S3Signer.emptyPayloadHash == sentHeaders["x-amz-content-sha256"])
		}

		@Test
		func deleteObjectsSendsHashesOfBody() async throws {
			let sentHashes = OSAllocatedUnfairLock<(contentMD5: String?, contentSHA256: String?)>(initialState: (nil, nil))
			let bodyHashes = OSAllocatedUnfairLock<(md5: String, sha256: String)?>(initialState: nil)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: { request in
				let body = URLProtocolMock.body(of: request)
				sentHashes.withLock { $0 = (request.value(forHTTPHeaderField: "Content-MD5"), request.value(forHTTPHeaderField: "x-amz-content-sha256")) }
				bodyHashes.withLock { $0 = (Data(Insecure.MD5.hash(data: body)).base64EncodedString(), S3Signer.sha256Hex(body)) }
			})]

			_ = try await client.deleteObjects(keys: ["a.txt", "folder/b.txt"])

			let sent = sentHashes.withLock { $0 }
			let expected = try #require(bodyHashes.withLock { $0 })
			#expect(expected.md5 == sent.contentMD5)
			#expect(expected.sha256 == sent.contentSHA256)
			#expect(S3Signer.emptyPayloadHash != sent.contentSHA256)
		}

		@Test
		func copySourceEncodesReservedCharacters() async throws {
			let copySource = OSAllocatedUnfairLock<String?>(initialState: nil)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: S3MockResponse.copyObjectResult, onRequest: { request in
				copySource.withLock { $0 = request.value(forHTTPHeaderField: "x-amz-copy-source") }
			})]

			try await client.copyObject(sourceKey: "folder/a+b&c=d é.txt", targetKey: "b.txt")

			#expect(copySource.withLock { $0 } == "exampleBucket/folder/a%2Bb%26c%3Dd%20%C3%A9.txt")
		}

		@Test
		func deleteObjectsReturnsRefusedKeys() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("a.txt", "AccessDenied")]))]

			let refusals = try await client.deleteObjects(keys: ["a.txt", "b.txt"])

			#expect([S3DeletionFailure(key: "a.txt", code: "AccessDenied")] == refusals)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Some servers report a key that doesn't exist, which counts as deleted.
		@Test
		func deleteObjectsDropsNoSuchKey() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("a.txt", "NoSuchKey")]))]

			let refusals = try await client.deleteObjects(keys: ["a.txt"])

			#expect(refusals == [])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func deleteObjectsResendsBatchOnTransientKeyError() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("b.txt", "SlowDown")]), onRequest: requests.record),
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("a.txt", "NoSuchKey")]), onRequest: requests.record)
			]

			let refusals = try await client.deleteObjects(keys: ["a.txt", "b.txt"])

			#expect(refusals == [])
			#expect(requests.requests.map { S3XMLElement.parse($0.httpBody ?? Data())?.children("Object").compactMap { $0.text(of: "Key") } } == [["a.txt", "b.txt"], ["a.txt", "b.txt"]])
			#expect(sleeps.durations.count == 1)
		}

		@Test
		func deleteObjectsThrowsTransientErrorAfterBudget() async throws {
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("a.txt", "SlowDown")])), count: 4)

			let error = try await #require(throws: (any Error).self) { try await client.deleteObjects(keys: ["a.txt"]) }
			#expect((error as? S3Error)?.code == "SlowDown")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A resend can't change the outcome of a permanent refusal, so the transient one is returned with it. A refusal without a code counts as permanent.
		@Test
		func deleteObjectsWithPermanentRefusalReturnsAtOnce() async throws {
			for permanentCode in ["AccessDenied", nil] {
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("a.txt", "SlowDown"), ("b.txt", permanentCode)])),
					URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: []))
				]

				let refusals = try await client.deleteObjects(keys: ["a.txt", "b.txt"])

				#expect([S3DeletionFailure(key: "a.txt", code: "SlowDown"), S3DeletionFailure(key: "b.txt", code: permanentCode)] == refusals)
				#expect(URLProtocolMock.requestHandler.count == 1)
				#expect(sleeps.durations == [])
			}
		}

		@Test
		func deleteObjectsWithTransientRefusalThenTransportFailureThrowsInterrupted() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("b.txt", "SlowDown")]))] + Array(repeating: S3MockResponse.failure(.timedOut), count: 3)

			let error = try await #require(throws: (any Error).self) { try await client.deleteObjects(keys: ["a.txt", "b.txt"]) }
			#expect(((error as? S3DeletionInterrupted)?.underlying as? URLError)?.code == .timedOut, "Unexpected error: \(error)")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func deleteObjectsWithTransientRequestRefusalThenTransportFailureThrowsInterrupted() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503)] + Array(repeating: S3MockResponse.failure(.timedOut), count: 3)

			let error = try await #require(throws: (any Error).self) { try await client.deleteObjects(keys: ["a.txt"]) }
			#expect(((error as? S3DeletionInterrupted)?.underlying as? URLError)?.code == .timedOut, "Unexpected error: \(error)")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func deleteObjectsWithClockSkewRefusalThenTransportFailureThrowsInterrupted() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(3600))])] + Array(repeating: S3MockResponse.failure(.timedOut), count: 4)

			let error = try await #require(throws: (any Error).self) { try await client.deleteObjects(keys: ["a.txt"]) }
			#expect(((error as? S3DeletionInterrupted)?.underlying as? URLError)?.code == .timedOut, "Unexpected error: \(error)")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A transport failure leaves the batch's outcome unknown, so it is thrown as it is unless S3 answered an earlier attempt.
		@Test
		func deleteObjectsWithTransportFailuresThrowsTransportError() async throws {
			URLProtocolMock.requestHandler = Array(repeating: S3MockResponse.failure(.timedOut), count: 4)

			let error = try await #require(throws: (any Error).self) { try await client.deleteObjects(keys: ["a.txt"]) }
			#expect((error as? URLError)?.code == .timedOut, "Unexpected error: \(error)")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The cancellation stops the resend of a transiently refused batch, and it stays a cancellation rather than an interrupted deletion.
		@Test
		func deleteObjectsCancelledAfterTransientRefusalThrowsCancellationError() async throws {
			let client: S3Client = client
			let canceller = TaskCanceller<[S3DeletionFailure]>()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("a.txt", "SlowDown")]), onRequest: { _ in
					canceller.cancel()
				}),
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: []))
			]

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: canceller.start {
					try await client.deleteObjects(keys: ["a.txt"])
				})
			}
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func errorCarriesBucketRegionHeader() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 301, body: "<Error><Code>PermanentRedirect</Code></Error>", headerFields: ["x-amz-bucket-region": "eu-central-1"])]

			let error = try await #require(throws: (any Error).self) { try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1) }
			#expect(S3Error(statusCode: 301, code: "PermanentRedirect", bucketRegion: "eu-central-1") == (error as? S3Error))
		}

		// MARK: - Retries

		@Test
		func retriesTransientStatus() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 429),
				URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["a.txt"]))
			]

			let result = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)

			#expect(result.contents.map(\.key) == ["a.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func retryWaitsForRetryAfter() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 503, headerFields: ["Retry-After": "2"]),
				URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["a.txt"]))
			]

			_ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)

			#expect([.seconds(2)] == sleeps.durations)
		}

		@Test
		func metadataBodyOverLimitFails() async throws {
			URLProtocolMock.requestHandler = [{ request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
			}]

			let error = try await #require(throws: (any Error).self) { try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1) }
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		@Test
		func doesNotRetryWithoutInternetConnection() async throws {
			URLProtocolMock.requestHandler = [
				{ _ in throw URLError(.notConnectedToInternet) },
				URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))
			]

			let error = try await #require(throws: (any Error).self) { try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1) }
			#expect((error as? URLError)?.code == .notConnectedToInternet)
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func retriesErrorDocumentInSuccessfulCopyResponse() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>"),
				URLProtocolMock.handler(body: S3MockResponse.copyObjectResult)
			]

			try await client.copyObject(sourceKey: "a.txt", targetKey: "b.txt")

			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func retriesPartCopyResponseThatWasCutShort() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: "     "),
				URLProtocolMock.handler(body: "<CopyPartResult><ETag>\"etag-2\"</ETag></CopyPartResult>")
			]

			let eTag = try await client.uploadPartCopy(sourceKey: "a.txt", range: "bytes=0-9", key: "b.txt", uploadID: "upload", partNumber: 1)

			#expect(eTag == "\"etag-2\"")
		}

		@Test
		func retriesUnreadableErrorDocumentInSuccessfulResponseWithoutResult() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: "<Error><Code>InternalError</Code>"),
				URLProtocolMock.handler(statusCode: 204)
			]

			try await client.deleteObject(key: "a.txt")

			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Multipart Upload Parts

		@Test
		func uploadPartReturnsETagOfPresignedPut() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(headerFields: ["ETag": "\"etag-2\""], onRequest: requests.record)]

			let eTag = try await client.uploadPart(key: "file.bin", uploadID: "upload-id", partNumber: 2, fromFile: makeLocalFile(), progress: nil)

			#expect(eTag == "\"etag-2\"")
			let request = try #require(requests.requests.first)
			#expect(request.httpMethod == "PUT")
			#expect(Data("content".utf8) == request.httpBody)
			#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
			let query = try #require(request.url?.query)
			for parameter in ["partNumber=2", "uploadId=upload-id", "X-Amz-Expires=3000", "X-Amz-Signature="] {
				#expect(query.contains(parameter), "\(query)")
			}
		}

		/// The retry is a further task, which gets its own unit of the progress before it starts, so that the finished first task counts only half.
		@Test
		func uploadPartRetriesTransientFailure() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractionAtRetry = OSAllocatedUnfairLock<Double?>(initialState: nil)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 503),
				URLProtocolMock.handler(headerFields: ["ETag": "\"etag-1\""], onRequest: { _ in
					fractionAtRetry.withLock { $0 = progress.fractionCompleted }
				})
			]

			let eTag = try await client.uploadPart(key: "file.bin", uploadID: "upload-id", partNumber: 1, fromFile: makeLocalFile(), progress: progress)

			#expect(eTag == "\"etag-1\"")
			#expect(sleeps.durations.count == 1)
			#expect(try abs(0.5 - #require(fractionAtRetry.withLock { $0 })) <= 0.01)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadPartStopsAfterThreeRetries() async throws {
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 4) + [URLProtocolMock.handler(headerFields: ["ETag": "\"etag-1\""])]

			let error = try await #require(throws: (any Error).self) { try await client.uploadPart(key: "file.bin", uploadID: "upload-id", partNumber: 1, fromFile: makeLocalFile(), progress: nil) }
			#expect((error as? S3Error)?.statusCode == 503)
			#expect(sleeps.durations.count == 3)
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func uploadPartDoesNotRetryAccessDenied() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>"),
				URLProtocolMock.handler(headerFields: ["ETag": "\"etag-1\""])
			]

			let error = try await #require(throws: (any Error).self) { try await client.uploadPart(key: "file.bin", uploadID: "upload-id", partNumber: 1, fromFile: makeLocalFile(), progress: nil) }
			#expect((error as? S3Error)?.code == "AccessDenied")
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func uploadPartWithoutETagThrows() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler()]

			let error = try await #require(throws: (any Error).self) { try await client.uploadPart(key: "file.bin", uploadID: "upload-id", partNumber: 1, fromFile: makeLocalFile(), progress: nil) }
			#expect((error as? URLError)?.code == .badServerResponse)
		}

		// MARK: - Clock Skew

		/// The corrected offset also signs later requests, including presigned transfers, which don't correct it themselves.
		@Test
		func correctsClockSkew() async throws {
			let dates = OSAllocatedUnfairLock(initialState: [String]())
			let recordDate: @Sendable (URLRequest) -> Void = { request in
				let presignedDate = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "X-Amz-Date" }?.value
				dates.withLock { $0.append(request.value(forHTTPHeaderField: "x-amz-date") ?? presignedDate ?? "") }
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(3600))], onRequest: recordDate),
				URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []), onRequest: recordDate),
				URLProtocolMock.handler(body: "content", onRequest: recordDate)
			]

			_ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)
			try await client.download(key: "file.txt", to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)

			let sentDates = try dates.withLock { $0 }.map { try #require(S3ClientTests.dateFormatter.date(from: $0)) }
			#expect(sentDates.count == 3)
			#expect(abs(3600 - sentDates[1].timeIntervalSince(sentDates[0])) <= 60)
			#expect(abs(3600 - sentDates[2].timeIntervalSince(sentDates[0])) <= 60)
		}

		/// The error code decides, whatever the status, as in the AWS SDKs: a 400 is neither retried as transient nor corrected otherwise.
		@Test
		func correctsClockSkewAfterRequestExpiredWithStatus400() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 400, body: "<Error><Code>RequestExpired</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(3600))]),
				URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))
			]

			_ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)
		}

		@Test
		func doesNotRetryAfterClockSkewInCancelledTask() async throws {
			let client: S3Client = client
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(3600))]),
				URLProtocolMock.handler()
			]

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: cancelledTask {
					try await client.putEmptyObject(key: "folder/", contentType: "application/x-directory")
				})
			}
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		/// Requests that were signed before another one corrected the offset still retry with the corrected one.
		@Test
		func correctsClockSkewOfConcurrentRequests() async throws {
			let client: S3Client = client
			let serverOffset: TimeInterval = 3600
			// Answers like a server whose clock is an hour ahead: a request signed with the device's clock is rejected.
			let skewedServer: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) = { request in
				let url = try #require(request.url)
				let signedDate = try #require(request.value(forHTTPHeaderField: "x-amz-date").flatMap { S3ClientTests.dateFormatter.date(from: $0) })
				let serverDate = Date().addingTimeInterval(serverOffset)
				guard abs(signedDate.timeIntervalSince(serverDate)) < 300 else {
					let response = try #require(HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: ["Date": Date.rfc822String(from: serverDate)]))
					return (response, Data("<Error><Code>RequestTimeTooSkewed</Code></Error>".utf8))
				}
				return try (#require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)), Data(S3MockResponse.listBucketResult(keys: []).utf8))
			}
			let requestCount = 5
			URLProtocolMock.requestHandler = Array(repeating: skewedServer, count: 2 * requestCount)

			try await withThrowingTaskGroup(of: Void.self) { group in
				for _ in 0 ..< requestCount {
					group.addTask {
						_ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)
					}
				}
				try await group.waitForAll()
			}
		}

		/// A rejected signature from a device whose clock matches the server's, e.g., because of a wrong secret key, is not retried.
		@Test
		func doesNotCorrectClockWithinTolerance() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>SignatureDoesNotMatch</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(60))]),
				URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))
			]

			let error = try await #require(throws: (any Error).self) { try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1) }
			#expect((error as? S3Error)?.code == "SignatureDoesNotMatch")
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func correctsClockSkewOnlyOnce() async throws {
			let skewedResponse = URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(3600))])
			let otherSkewedResponse = URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(-3600))])
			URLProtocolMock.requestHandler = [skewedResponse, otherSkewedResponse, URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))]

			let error = try await #require(throws: (any Error).self) { try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1) }
			#expect((error as? S3Error)?.code == "RequestTimeTooSkewed")
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		// MARK: - Sessions

		@Test
		func testBackgroundConfiguration() {
			let configuration = S3Client.backgroundConfiguration(sessionIdentifier: "S3ClientTests", sharedContainerIdentifier: "group.test")

			#expect(configuration.identifier == "S3ClientTests")
			#expect(configuration.sharedContainerIdentifier == "group.test")
			#expect(50 * 60 == configuration.timeoutIntervalForResource)
			#expect(configuration.urlCache == nil)
			#expect(configuration.urlCredentialStorage == nil)
		}

		@Test
		func transfersUsePresignedURLs() async throws {
			let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
			let recordRequest: @Sendable (URLRequest) -> Void = { request in
				requests.withLock { $0.append(request) }
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: "content", onRequest: recordRequest),
				URLProtocolMock.handler(onRequest: recordRequest)
			]
			let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
			try Data("content".utf8).write(to: fileURL)

			try await client.download(key: "file.txt", to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)
			try await client.upload(key: "file.txt", fromFile: fileURL, contentType: "text/plain", progress: nil, onTaskCreation: nil)

			let sentRequests = requests.withLock { $0 }
			#expect(sentRequests.map(\.httpMethod) == ["GET", "PUT"])
			for request in sentRequests {
				let query = try #require(request.url?.query)
				#expect(query.contains("X-Amz-Expires=3000"), "\(query)")
				#expect(query.contains("X-Amz-Signature="), "\(query)")
				#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
			}
			#expect(try #require(sentRequests.last?.url?.query).contains("X-Amz-SignedHeaders=content-type%3Bhost"))
			#expect(try Data("content".utf8) == Data(contentsOf: tmpDirURL.appendingPathComponent("download.txt")))
		}

		@Test
		func backgroundClientRunsOnlyTransfersOnBackgroundSession() async throws {
			let registry = BackgroundURLSessionRegistry { _ in URLProtocolMock.configuration(marker: "transfer") }
			let backgroundClient = try S3Client(credential: .stub, configuration: .background(withIdentifier: "S3ClientTests"), metadataConfiguration: URLProtocolMock.configuration(marker: "metadata"), registry: registry)
			let markers = OSAllocatedUnfairLock(initialState: [String?]())
			let recordMarker: @Sendable (URLRequest) -> Void = { request in
				markers.withLock { $0.append(request.value(forHTTPHeaderField: "X-Session")) }
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []), onRequest: recordMarker),
				URLProtocolMock.handler(body: "content", onRequest: recordMarker),
				URLProtocolMock.handler(onRequest: recordMarker)
			]
			let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
			try Data("content".utf8).write(to: fileURL)

			_ = try await backgroundClient.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)
			try await backgroundClient.download(key: "file.txt", to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)
			try await backgroundClient.upload(key: "file.txt", fromFile: fileURL, contentType: "text/plain", progress: nil, onTaskCreation: nil)

			#expect(markers.withLock { $0 } == ["metadata", "transfer", "transfer"])
		}

		// MARK: - Logging

		@Test
		func failuresLeaveNoSigningDetailsInLogOrError() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let secretKey = "SECRETKEY123"
			let client = try S3Client.mocked(credential: S3Credential(accessKey: "access", secretKey: secretKey, url: S3Credential.stub.url, bucket: S3Credential.stub.bucket, region: S3Credential.stub.region, forcePathStyle: S3Credential.stub.forcePathStyle))
			let presignedSignature = OSAllocatedUnfairLock<String?>(initialState: nil)
			let signingDetails = "<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided.</Message><AWSAccessKeyId>access</AWSAccessKeyId><StringToSign>STRINGTOSIGN</StringToSign><SignatureProvided>PROVIDEDSIGNATURE</SignatureProvided><CanonicalRequest>CANONICALREQUEST</CanonicalRequest></Error>"
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 403, body: signingDetails),
				{ request in
					let url = try #require(request.url)
					presignedSignature.withLock { $0 = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "X-Amz-Signature" }?.value }
					throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])
				},
				URLProtocolMock.handler(statusCode: 403, body: signingDetails),
				URLProtocolMock.handler(statusCode: 403, body: signingDetails)
			]
			let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
			try Data("content".utf8).write(to: fileURL)
			let downloadURL = tmpDirURL.appendingPathComponent("download.txt")
			let operations: [@Sendable () async throws -> Void] = [
				{ _ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1) },
				{ try await client.download(key: "file.txt", to: downloadURL, progress: nil, onTaskCreation: nil) },
				{ try await client.download(key: "file.txt", to: downloadURL, progress: nil, onTaskCreation: nil) },
				{ try await client.upload(key: "file.txt", fromFile: fileURL, contentType: "text/plain", progress: nil, onTaskCreation: nil) }
			]
			var errors = [Error]()

			for operation in operations {
				do {
					try await operation()
				} catch {
					errors.append(error)
				}
			}

			#expect(errors.count == 4)
			#expect((errors[1] as? URLError)?.code == .timedOut)
			for index in [0, 2, 3] {
				#expect((errors[index] as? S3Error)?.code == "SignatureDoesNotMatch")
			}
			let signature = try #require(presignedSignature.withLock { $0 })
			for text in [logCapture.joinedMessages] + errors.map({ String(describing: $0) }) {
				for secret in [secretKey, signature, "STRINGTOSIGN", "PROVIDEDSIGNATURE", "CANONICALREQUEST"] {
					#expect(!text.contains(secret), "\(secret) in \(text)")
				}
				#expect(text.range(of: "X-Amz-Signature=[0-9a-f]", options: .regularExpression) == nil, "\(text)")
			}
		}

		// MARK: - Helpers

		private func makeLocalFile() throws -> URL {
			let fileURL = tmpDirURL.appendingPathComponent("part.bin")
			try Data("content".utf8).write(to: fileURL)
			return fileURL
		}

		private static let dateFormatter = {
			let formatter = DateFormatter()
			formatter.locale = Locale(identifier: "en_US_POSIX")
			formatter.timeZone = TimeZone(identifier: "UTC")
			formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
			return formatter
		}()
	}
}

extension S3Client {
	/// Returns a client whose requests `URLProtocolMock` answers.
	static func mocked(credential: S3Credential = .stub, sleeps: SleepRecorder = SleepRecorder(), hooks: SplitURLSession.Hooks = SplitURLSession.Hooks()) throws -> S3Client {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return try S3Client(credential: credential, configuration: configuration, metadataConfiguration: nil, hooks: hooks, sleep: { sleeps.sleep(for: $0) })
	}
}

enum S3MockResponse {
	static let completeMultipartUploadResult = "<CompleteMultipartUploadResult><ETag>\"etag\"</ETag></CompleteMultipartUploadResult>"
	static let copyObjectResult = "<CopyObjectResult><ETag>\"etag\"</ETag></CopyObjectResult>"
	static func deleteResult(errors: [(key: String, code: String?)]) -> String {
		let entries = errors.map { error in
			"<Error><Key>\(error.key)</Key>\(error.code.map { "<Code>\($0)</Code>" } ?? "")<Message>message</Message></Error>"
		}.joined()
		return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\(entries)</DeleteResult>"
	}

	static func failure(_ code: URLError.Code, _ requests: RequestRecorder = RequestRecorder()) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
		return { request in
			requests.record(request)
			throw URLError(code)
		}
	}

	static func initiateMultipartUploadResult(uploadID: String = "upload-id") -> String {
		return "<InitiateMultipartUploadResult><Bucket>exampleBucket</Bucket><Key>b.txt</Key><UploadId>\(uploadID)</UploadId></InitiateMultipartUploadResult>"
	}

	static func listBucketResult(keys: [String], commonPrefixes: [String] = [], nextContinuationToken: String? = nil, size: Int = 7, lastModified: String = "2026-10-18T12:34:56.000Z") -> String {
		let contents = keys.map { "<Contents><Key>\($0)</Key><LastModified>\(lastModified)</LastModified><Size>\(size)</Size></Contents>" }.joined()
		let prefixes = commonPrefixes.map { "<CommonPrefixes><Prefix>\($0)</Prefix></CommonPrefixes>" }.joined()
		let continuation = nextContinuationToken.map { "<IsTruncated>true</IsTruncated><NextContinuationToken>\($0)</NextContinuationToken>" } ?? "<IsTruncated>false</IsTruncated>"
		return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\(continuation)\(contents)\(prefixes)</ListBucketResult>"
	}
}

private extension Date {
	private static let rfc822Formatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "GMT")
		formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
		return formatter
	}()

	static func rfc822String(from date: Date) -> String {
		return rfc822Formatter.string(from: date)
	}
}
