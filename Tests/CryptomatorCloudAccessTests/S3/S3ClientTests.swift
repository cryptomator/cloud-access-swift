//
//  S3ClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class S3ClientTests: XCTestCase {
	private var sleeps: SleepRecorder!
	private var client: S3Client!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		sleeps = SleepRecorder()
		client = try S3Client.mocked(sleeps: sleeps)
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - Signing

	func testRequestsAreSigned() async throws {
		let headers = OSAllocatedUnfairLock(initialState: [String: String]())
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []), onRequest: { request in
			headers.withLock { $0 = request.allHTTPHeaderFields ?? [:] }
		})]

		_ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)

		let sentHeaders = headers.withLock { $0 }
		XCTAssertTrue(sentHeaders["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 Credential=access/") ?? false, "\(sentHeaders)")
		XCTAssertNotNil(sentHeaders["x-amz-date"])
		XCTAssertEqual(S3Signer.emptyPayloadHash, sentHeaders["x-amz-content-sha256"])
	}

	func testDeleteObjectsSendsHashesOfBody() async throws {
		let sentHashes = OSAllocatedUnfairLock<(contentMD5: String?, contentSHA256: String?)>(initialState: (nil, nil))
		let bodyHashes = OSAllocatedUnfairLock<(md5: String, sha256: String)?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: { request in
			let body = URLProtocolMock.body(of: request)
			sentHashes.withLock { $0 = (request.value(forHTTPHeaderField: "Content-MD5"), request.value(forHTTPHeaderField: "x-amz-content-sha256")) }
			bodyHashes.withLock { $0 = (Data(Insecure.MD5.hash(data: body)).base64EncodedString(), S3Signer.sha256Hex(body)) }
		})]

		try await client.deleteObjects(keys: ["a.txt", "folder/b.txt"])

		let sent = sentHashes.withLock { $0 }
		let expected = try XCTUnwrap(bodyHashes.withLock { $0 })
		XCTAssertEqual(expected.md5, sent.contentMD5)
		XCTAssertEqual(expected.sha256, sent.contentSHA256)
		XCTAssertNotEqual(S3Signer.emptyPayloadHash, sent.contentSHA256)
	}

	func testCopySourceEncodesReservedCharacters() async throws {
		let copySource = OSAllocatedUnfairLock<String?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "<CopyObjectResult><ETag>\"etag\"</ETag></CopyObjectResult>", onRequest: { request in
			copySource.withLock { $0 = request.value(forHTTPHeaderField: "x-amz-copy-source") }
		})]

		try await client.copyObject(sourceKey: "folder/a+b&c=d é.txt", targetKey: "b.txt")

		XCTAssertEqual("exampleBucket/folder/a%2Bb%26c%3Dd%20%C3%A9.txt", copySource.withLock { $0 })
	}

	func testDeleteObjectsIgnoresErrorsOfSingleObjects() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "<DeleteResult><Error><Key>a.txt</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error></DeleteResult>")]

		try await client.deleteObjects(keys: ["a.txt"])

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testErrorCarriesBucketRegionHeader() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 301, body: "<Error><Code>PermanentRedirect</Code></Error>", headerFields: ["x-amz-bucket-region": "eu-central-1"])]

		await XCTAssertThrowsErrorAsync(try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)) { error in
			XCTAssertEqual(S3Error(statusCode: 301, code: "PermanentRedirect", bucketRegion: "eu-central-1"), error as? S3Error)
		}
	}

	// MARK: - Retries

	func testRetriesTransientStatus() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 429),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["a.txt"]))
		]

		let result = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)

		XCTAssertEqual(["a.txt"], result.contents.map(\.key))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testRetryWaitsForRetryAfter() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 503, headerFields: ["Retry-After": "2"]),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["a.txt"]))
		]

		_ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)

		XCTAssertEqual([.seconds(2)], sleeps.durations)
	}

	func testMetadataBodyOverLimitFails() async throws {
		URLProtocolMock.requestHandler = [{ request in
			(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
		}]

		await XCTAssertThrowsErrorAsync(try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)) { error in
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				return XCTFail("Unexpected error: \(error)")
			}
		}
	}

	func testDoesNotRetryWithoutInternetConnection() async throws {
		URLProtocolMock.requestHandler = [
			{ _ in throw URLError(.notConnectedToInternet) },
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))
		]

		await XCTAssertThrowsErrorAsync(try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)) { error in
			XCTAssertEqual(.notConnectedToInternet, (error as? URLError)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testRetriesErrorDocumentInSuccessfulCopyResponse() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>"),
			URLProtocolMock.handler(body: "<CopyObjectResult><ETag>\"etag\"</ETag></CopyObjectResult>")
		]

		try await client.copyObject(sourceKey: "a.txt", targetKey: "b.txt")

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testRetriesPartCopyResponseThatWasCutShort() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: "     "),
			URLProtocolMock.handler(body: "<CopyPartResult><ETag>\"etag-2\"</ETag></CopyPartResult>")
		]

		let eTag = try await client.uploadPartCopy(sourceKey: "a.txt", range: "bytes=0-9", key: "b.txt", uploadID: "upload", partNumber: 1)

		XCTAssertEqual("\"etag-2\"", eTag)
	}

	func testRetriesUnreadableErrorDocumentInSuccessfulResponseWithoutResult() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: "<Error><Code>InternalError</Code>"),
			URLProtocolMock.handler(statusCode: 204)
		]

		try await client.deleteObject(key: "a.txt")

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	// MARK: - Multipart Upload Parts

	func testUploadPartReturnsETagOfPresignedPut() async throws {
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(headerFields: ["ETag": "\"etag-2\""], onRequest: requests.record)]

		let eTag = try await client.uploadPart(key: "file.bin", uploadID: "upload-id", partNumber: 2, fromFile: makeLocalFile(), progress: nil)

		XCTAssertEqual("\"etag-2\"", eTag)
		let request = try XCTUnwrap(requests.requests.first)
		XCTAssertEqual("PUT", request.httpMethod)
		XCTAssertEqual(Data("content".utf8), request.httpBody)
		XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
		let query = try XCTUnwrap(request.url?.query)
		for parameter in ["partNumber=2", "uploadId=upload-id", "X-Amz-Expires=3000", "X-Amz-Signature="] {
			XCTAssertTrue(query.contains(parameter), query)
		}
	}

	/// The retry is a further task, which gets its own unit of the progress before it starts, so that the finished first task counts only half.
	func testUploadPartRetriesTransientFailure() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractionAtRetry = OSAllocatedUnfairLock<Double?>(initialState: nil)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 503),
			URLProtocolMock.handler(headerFields: ["ETag": "\"etag-1\""], onRequest: { _ in
				fractionAtRetry.withLock { $0 = progress.fractionCompleted }
			})
		]

		let eTag = try await client.uploadPart(key: "file.bin", uploadID: "upload-id", partNumber: 1, fromFile: makeLocalFile(), progress: progress)

		XCTAssertEqual("\"etag-1\"", eTag)
		XCTAssertEqual(1, sleeps.durations.count)
		XCTAssertEqual(0.5, try XCTUnwrap(fractionAtRetry.withLock { $0 }), accuracy: 0.01)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadPartStopsAfterThreeRetries() async throws {
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 4) + [URLProtocolMock.handler(headerFields: ["ETag": "\"etag-1\""])]

		await XCTAssertThrowsErrorAsync(try await client.uploadPart(key: "file.bin", uploadID: "upload-id", partNumber: 1, fromFile: makeLocalFile(), progress: nil)) { error in
			XCTAssertEqual(503, (error as? S3Error)?.statusCode)
		}
		XCTAssertEqual(3, sleeps.durations.count)
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testUploadPartDoesNotRetryAccessDenied() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>"),
			URLProtocolMock.handler(headerFields: ["ETag": "\"etag-1\""])
		]

		await XCTAssertThrowsErrorAsync(try await client.uploadPart(key: "file.bin", uploadID: "upload-id", partNumber: 1, fromFile: makeLocalFile(), progress: nil)) { error in
			XCTAssertEqual("AccessDenied", (error as? S3Error)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testUploadPartWithoutETagThrows() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler()]

		await XCTAssertThrowsErrorAsync(try await client.uploadPart(key: "file.bin", uploadID: "upload-id", partNumber: 1, fromFile: makeLocalFile(), progress: nil)) { error in
			XCTAssertEqual(.badServerResponse, (error as? URLError)?.code)
		}
	}

	// MARK: - Clock Skew

	/// The corrected offset also signs later requests, including presigned transfers, which don't correct it themselves.
	func testCorrectsClockSkew() async throws {
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

		let sentDates = try dates.withLock { $0 }.map { try XCTUnwrap(S3ClientTests.dateFormatter.date(from: $0)) }
		XCTAssertEqual(3, sentDates.count)
		XCTAssertEqual(3600, sentDates[1].timeIntervalSince(sentDates[0]), accuracy: 60)
		XCTAssertEqual(3600, sentDates[2].timeIntervalSince(sentDates[0]), accuracy: 60)
	}

	/// The error code decides, whatever the status, as in the AWS SDKs: a 400 is neither retried as transient nor corrected otherwise.
	func testCorrectsClockSkewAfterRequestExpiredWithStatus400() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 400, body: "<Error><Code>RequestExpired</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(3600))]),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))
		]

		_ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)
	}

	func testDoesNotRetryAfterClockSkewInCancelledTask() async throws {
		let client: S3Client = client
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(3600))]),
			URLProtocolMock.handler()
		]

		await XCTAssertThrowsErrorAsync(try await value(of: cancelledTask {
			try await client.putEmptyObject(key: "folder/", contentType: "application/x-directory")
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	/// Requests that were signed before another one corrected the offset still retry with the corrected one.
	func testCorrectsClockSkewOfConcurrentRequests() async throws {
		let client: S3Client = client
		let serverOffset: TimeInterval = 3600
		// Answers like a server whose clock is an hour ahead: a request signed with the device's clock is rejected.
		let skewedServer: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) = { request in
			let url = try XCTUnwrap(request.url)
			let signedDate = try XCTUnwrap(request.value(forHTTPHeaderField: "x-amz-date").flatMap { S3ClientTests.dateFormatter.date(from: $0) })
			let serverDate = Date().addingTimeInterval(serverOffset)
			guard abs(signedDate.timeIntervalSince(serverDate)) < 300 else {
				let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: ["Date": Date.rfc822String(from: serverDate)]))
				return (response, Data("<Error><Code>RequestTimeTooSkewed</Code></Error>".utf8))
			}
			return try (XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)), Data(S3MockResponse.listBucketResult(keys: []).utf8))
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
	func testDoesNotCorrectClockWithinTolerance() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>SignatureDoesNotMatch</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(60))]),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))
		]

		await XCTAssertThrowsErrorAsync(try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)) { error in
			XCTAssertEqual("SignatureDoesNotMatch", (error as? S3Error)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testCorrectsClockSkewOnlyOnce() async throws {
		let skewedResponse = URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(3600))])
		let otherSkewedResponse = URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(-3600))])
		URLProtocolMock.requestHandler = [skewedResponse, otherSkewedResponse, URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))]

		await XCTAssertThrowsErrorAsync(try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)) { error in
			XCTAssertEqual("RequestTimeTooSkewed", (error as? S3Error)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	// MARK: - Sessions

	func testBackgroundConfiguration() {
		let configuration = S3Client.backgroundConfiguration(sessionIdentifier: "S3ClientTests", sharedContainerIdentifier: "group.test")

		XCTAssertEqual("S3ClientTests", configuration.identifier)
		XCTAssertEqual("group.test", configuration.sharedContainerIdentifier)
		XCTAssertEqual(50 * 60, configuration.timeoutIntervalForResource)
		XCTAssertNil(configuration.urlCache)
		XCTAssertNil(configuration.urlCredentialStorage)
	}

	func testTransfersUsePresignedURLs() async throws {
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
		XCTAssertEqual(["GET", "PUT"], sentRequests.map(\.httpMethod))
		for request in sentRequests {
			let query = try XCTUnwrap(request.url?.query)
			XCTAssertTrue(query.contains("X-Amz-Expires=3000"), query)
			XCTAssertTrue(query.contains("X-Amz-Signature="), query)
			XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
		}
		XCTAssertTrue(try XCTUnwrap(sentRequests.last?.url?.query).contains("X-Amz-SignedHeaders=content-type%3Bhost"))
		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: tmpDirURL.appendingPathComponent("download.txt")))
	}

	func testBackgroundClientRunsOnlyTransfersOnBackgroundSession() async throws {
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

		XCTAssertEqual(["metadata", "transfer", "transfer"], markers.withLock { $0 })
	}

	// MARK: - Logging

	func testFailuresLeaveNoSigningDetailsInLogOrError() async throws {
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
				let url = try XCTUnwrap(request.url)
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

		XCTAssertEqual(4, errors.count)
		XCTAssertEqual(.timedOut, (errors[1] as? URLError)?.code)
		for index in [0, 2, 3] {
			XCTAssertEqual("SignatureDoesNotMatch", (errors[index] as? S3Error)?.code)
		}
		let signature = try XCTUnwrap(presignedSignature.withLock { $0 })
		for text in [logCapture.joinedMessages] + errors.map({ String(describing: $0) }) {
			for secret in [secretKey, signature, "STRINGTOSIGN", "PROVIDEDSIGNATURE", "CANONICALREQUEST"] {
				XCTAssertFalse(text.contains(secret), "\(secret) in \(text)")
			}
			XCTAssertNil(text.range(of: "X-Amz-Signature=[0-9a-f]", options: .regularExpression), text)
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
