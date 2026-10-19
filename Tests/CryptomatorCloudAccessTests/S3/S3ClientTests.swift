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
	private var client: S3Client!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		client = S3Client.mocked()
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
		URLProtocolMock.requestHandler = [S3MockResponse.handler(statusCode: 200, body: S3MockResponse.listBucketResult(keys: []), onRequest: { request in
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
		URLProtocolMock.requestHandler = [S3MockResponse.handler(statusCode: 200, body: "<DeleteResult/>", onRequest: { request in
			let body = S3MockResponse.body(of: request)
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
		URLProtocolMock.requestHandler = [S3MockResponse.handler(statusCode: 200, body: "<CopyObjectResult><ETag>\"etag\"</ETag></CopyObjectResult>", onRequest: { request in
			copySource.withLock { $0 = request.value(forHTTPHeaderField: "x-amz-copy-source") }
		})]

		try await client.copyObject(sourceKey: "folder/a+b&c=d é.txt", targetKey: "b.txt")

		XCTAssertEqual("exampleBucket/folder/a%2Bb%26c%3Dd%20%C3%A9.txt", copySource.withLock { $0 })
	}

	func testDeleteObjectsIgnoresErrorsOfSingleObjects() async throws {
		URLProtocolMock.requestHandler = [S3MockResponse.handler(statusCode: 200, body: "<DeleteResult><Error><Key>a.txt</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error></DeleteResult>")]

		try await client.deleteObjects(keys: ["a.txt"])

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	// MARK: - Retries

	func testRetriesTransientStatus() async throws {
		URLProtocolMock.requestHandler = [
			S3MockResponse.handler(statusCode: 503),
			S3MockResponse.handler(statusCode: 200, body: S3MockResponse.listBucketResult(keys: ["a.txt"]))
		]

		let result = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)

		XCTAssertEqual(["a.txt"], result.contents.map(\.key))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDoesNotRetryWithoutInternetConnection() async throws {
		URLProtocolMock.requestHandler = [
			{ _ in throw URLError(.notConnectedToInternet) },
			S3MockResponse.handler(statusCode: 200, body: S3MockResponse.listBucketResult(keys: []))
		]

		await XCTAssertThrowsErrorAsync(try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)) { error in
			XCTAssertEqual(.notConnectedToInternet, (error as? URLError)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testRetriesErrorDocumentInSuccessfulCopyResponse() async throws {
		URLProtocolMock.requestHandler = [
			S3MockResponse.handler(statusCode: 200, body: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>"),
			S3MockResponse.handler(statusCode: 200, body: "<CopyObjectResult><ETag>\"etag\"</ETag></CopyObjectResult>")
		]

		try await client.copyObject(sourceKey: "a.txt", targetKey: "b.txt")

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testRetriesPartCopyResponseThatWasCutShort() async throws {
		URLProtocolMock.requestHandler = [
			S3MockResponse.handler(statusCode: 200, body: "     "),
			S3MockResponse.handler(statusCode: 200, body: "<CopyPartResult><ETag>\"etag-2\"</ETag></CopyPartResult>")
		]

		let eTag = try await client.uploadPartCopy(sourceKey: "a.txt", range: "bytes=0-9", key: "b.txt", uploadID: "upload", partNumber: 1)

		XCTAssertEqual("\"etag-2\"", eTag)
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
			S3MockResponse.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(3600))], onRequest: recordDate),
			S3MockResponse.handler(statusCode: 200, body: S3MockResponse.listBucketResult(keys: []), onRequest: recordDate),
			S3MockResponse.handler(statusCode: 200, body: "content", onRequest: recordDate)
		]

		_ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)
		try await client.download(key: "file.txt", to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)

		let sentDates = try dates.withLock { $0 }.map { try XCTUnwrap(S3ClientTests.dateFormatter.date(from: $0)) }
		XCTAssertEqual(3, sentDates.count)
		XCTAssertEqual(3600, sentDates[1].timeIntervalSince(sentDates[0]), accuracy: 60)
		XCTAssertEqual(3600, sentDates[2].timeIntervalSince(sentDates[0]), accuracy: 60)
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
			S3MockResponse.handler(statusCode: 403, body: "<Error><Code>SignatureDoesNotMatch</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(60))]),
			S3MockResponse.handler(statusCode: 200, body: S3MockResponse.listBucketResult(keys: []))
		]

		await XCTAssertThrowsErrorAsync(try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)) { error in
			XCTAssertEqual("SignatureDoesNotMatch", (error as? S3Error)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testCorrectsClockSkewOnlyOnce() async throws {
		let skewedResponse = S3MockResponse.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(3600))])
		let otherSkewedResponse = S3MockResponse.handler(statusCode: 403, body: "<Error><Code>RequestTimeTooSkewed</Code></Error>", headerFields: ["Date": Date.rfc822String(from: Date().addingTimeInterval(-3600))])
		URLProtocolMock.requestHandler = [skewedResponse, otherSkewedResponse, S3MockResponse.handler(statusCode: 200, body: S3MockResponse.listBucketResult(keys: []))]

		await XCTAssertThrowsErrorAsync(try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)) { error in
			XCTAssertEqual("RequestTimeTooSkewed", (error as? S3Error)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	// MARK: - Sessions

	func testBackgroundConfiguration() {
		let configuration = S3Client.backgroundConfiguration(credential: .stub, sharedContainerIdentifier: "group.test")

		XCTAssertEqual("CryptomatorCloudAccess.S3.\(S3Credential.stub.identifier)", configuration.identifier)
		XCTAssertEqual("group.test", configuration.sharedContainerIdentifier)
		XCTAssertEqual(50 * 60, configuration.timeoutIntervalForResource)
		XCTAssertNil(configuration.urlCache)
		XCTAssertNil(configuration.urlCredentialStorage)
	}

	func testHardenedConfigurationsCacheNothing() {
		for configuration in [S3Client.hardened(.default), S3Client.hardened(.background(withIdentifier: "test"))] {
			XCTAssertNil(configuration.urlCache)
			XCTAssertNil(configuration.urlCredentialStorage)
			XCTAssertNotNil(configuration.httpCookieStorage)
			XCTAssertFalse(configuration.httpCookieStorage === HTTPCookieStorage.shared)
		}
	}

	func testTransfersUsePresignedURLs() async throws {
		let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
		let recordRequest: @Sendable (URLRequest) -> Void = { request in
			requests.withLock { $0.append(request) }
		}
		URLProtocolMock.requestHandler = [
			S3MockResponse.handler(statusCode: 200, body: "content", onRequest: recordRequest),
			S3MockResponse.handler(statusCode: 200, onRequest: recordRequest)
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
		let backgroundClient = S3Client(credential: .stub, configuration: .background(withIdentifier: "S3ClientTests"), metadataConfiguration: URLProtocolMock.configuration(marker: "metadata"), registry: registry)
		let markers = OSAllocatedUnfairLock(initialState: [String?]())
		let recordMarker: @Sendable (URLRequest) -> Void = { request in
			markers.withLock { $0.append(request.value(forHTTPHeaderField: "X-Session")) }
		}
		URLProtocolMock.requestHandler = [
			S3MockResponse.handler(statusCode: 200, body: S3MockResponse.listBucketResult(keys: []), onRequest: recordMarker),
			S3MockResponse.handler(statusCode: 200, body: "content", onRequest: recordMarker),
			S3MockResponse.handler(statusCode: 200, onRequest: recordMarker)
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
		let client = S3Client.mocked(credential: S3Credential(accessKey: "access", secretKey: secretKey, url: S3Credential.stub.url, bucket: S3Credential.stub.bucket, region: S3Credential.stub.region))
		let presignedSignature = OSAllocatedUnfairLock<String?>(initialState: nil)
		let signingDetails = "<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided.</Message><AWSAccessKeyId>access</AWSAccessKeyId><StringToSign>STRINGTOSIGN</StringToSign><SignatureProvided>PROVIDEDSIGNATURE</SignatureProvided><CanonicalRequest>CANONICALREQUEST</CanonicalRequest></Error>"
		URLProtocolMock.requestHandler = [
			S3MockResponse.handler(statusCode: 403, body: signingDetails),
			{ request in
				let url = try XCTUnwrap(request.url)
				presignedSignature.withLock { $0 = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "X-Amz-Signature" }?.value }
				throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])
			},
			S3MockResponse.handler(statusCode: 403, body: signingDetails),
			S3MockResponse.handler(statusCode: 403, body: signingDetails)
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

	func testSanitizedErrorDropsFailingURLsOfNestedErrors() throws {
		let url = try XCTUnwrap(URL(string: "https://www.example.com/exampleBucket/file.txt?X-Amz-Signature=0123abcd"))
		let underlyingError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])
		let error = NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(CFNetworkErrors.cfErrorHTTPParseFailure.rawValue), userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString, NSUnderlyingErrorKey: underlyingError])

		let sanitizedError = S3Client.sanitized(error) as NSError

		XCTAssertEqual(kCFErrorDomainCFNetwork as String, sanitizedError.domain)
		XCTAssertEqual(Int(CFNetworkErrors.cfErrorHTTPParseFailure.rawValue), sanitizedError.code)
		XCTAssertEqual(.timedOut, (sanitizedError.userInfo[NSUnderlyingErrorKey] as? URLError)?.code)
		XCTAssertFalse(String(describing: sanitizedError).contains("0123abcd"), "\(sanitizedError)")
	}

	// MARK: - Helpers

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
	static func mocked(credential: S3Credential = .stub) -> S3Client {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return S3Client(credential: credential, configuration: configuration, metadataConfiguration: nil)
	}
}

enum S3MockResponse {
	static func handler(statusCode: Int, body: String = "", headerFields: [String: String]? = nil, onRequest: @escaping @Sendable (URLRequest) -> Void = { _ in }) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
		return { request in
			onRequest(request)
			let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headerFields))
			return (response, Data(body.utf8))
		}
	}

	static func listBucketResult(keys: [String], commonPrefixes: [String] = [], nextContinuationToken: String? = nil, size: Int = 7) -> String {
		let contents = keys.map { "<Contents><Key>\($0)</Key><LastModified>2026-10-18T12:34:56.000Z</LastModified><Size>\(size)</Size></Contents>" }.joined()
		let prefixes = commonPrefixes.map { "<CommonPrefixes><Prefix>\($0)</Prefix></CommonPrefixes>" }.joined()
		let continuation = nextContinuationToken.map { "<IsTruncated>true</IsTruncated><NextContinuationToken>\($0)</NextContinuationToken>" } ?? "<IsTruncated>false</IsTruncated>"
		return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\(continuation)\(contents)\(prefixes)</ListBucketResult>"
	}

	/// The body of a request that a `URLProtocol` receives, which URLSession usually passes as a stream.
	static func body(of request: URLRequest) -> Data {
		if let body = request.httpBody {
			return body
		}
		guard let stream = request.httpBodyStream else {
			return Data()
		}
		stream.open()
		defer {
			stream.close()
		}
		var body = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		while true {
			let count = stream.read(&buffer, maxLength: buffer.count)
			guard count > 0 else {
				return body
			}
			body.append(buffer, count: count)
		}
	}
}
