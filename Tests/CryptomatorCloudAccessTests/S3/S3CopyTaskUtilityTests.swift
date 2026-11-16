//
//  S3CopyTaskUtilityTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
@testable import CryptomatorCloudAccessCore

class S3CopyTaskUtilityTests: XCTestCase {
	override func tearDown() {
		URLProtocolMock.requestHandler = []
	}

	/// Each part copies its own range of the source into the target's upload, and the completion lists every part in order with the ETag of its copy.
	func testMultipartCopyCompletesPartsInOrder() async throws {
		let copyTaskUtility = try S3CopyTaskUtility(client: .mocked(), maxPartSize: 10)
		let requests = RequestRecorder()
		let ranges = OSAllocatedUnfairLock(initialState: [String: String]())
		let partCopy: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) = { request in
			requests.record(request)
			let url = try XCTUnwrap(request.url)
			let partNumber = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "partNumber" }?.value)
			ranges.withLock { $0[partNumber] = request.value(forHTTPHeaderField: "x-amz-copy-source-range") }
			return try (XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)), Data("<CopyPartResult><ETag>\"etag-\(partNumber)\"</ETag></CopyPartResult>".utf8))
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.initiateMultipartUploadResult(uploadID: "copy-upload-id"), onRequest: requests.record),
			partCopy,
			partCopy,
			partCopy,
			URLProtocolMock.handler(body: S3MockResponse.completeMultipartUploadResult, onRequest: requests.record)
		]

		try await copyTaskUtility.copy(S3CopyRequest(sourceKey: "a.txt", targetKey: "b.txt", itemSize: 25))

		XCTAssertEqual(["1": "bytes=0-9", "2": "bytes=10-19", "3": "bytes=20-24"], ranges.withLock { $0 })
		let sent = requests.requests
		XCTAssertEqual(Array(repeating: "/exampleBucket/b.txt", count: 5), sent.map { $0.url?.path })
		XCTAssertEqual(Array(repeating: "copy-upload-id", count: 4), sent.dropFirst().map(S3CopyTaskUtilityTests.uploadID(of:)))
		XCTAssertEqual(Array(repeating: "exampleBucket/a.txt", count: 3), sent[1 ... 3].map { $0.value(forHTTPHeaderField: "x-amz-copy-source") })
		let body = try XCTUnwrap(sent.last?.httpBody.flatMap { String(bytes: $0, encoding: .utf8) })
		XCTAssertTrue(body.contains("<Part><PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag></Part><Part><PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag></Part><Part><PartNumber>3</PartNumber><ETag>&quot;etag-3&quot;</ETag></Part></CompleteMultipartUpload>"), body)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// The objects that fit in one request are copied before the multipart copies, which run one after another, so that the parts of several objects never add up beyond `concurrencyLimit` requests in flight.
	func testMultipartCopiesRunAfterRegularCopiesOneAtATime() async throws {
		let copyTaskUtility = try S3CopyTaskUtility(client: .mocked(), maxPartSize: 10)
		let requests = RequestRecorder()
		let answer: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) = { request in
			let url = try XCTUnwrap(request.url)
			let queryNames = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
			let body = if queryNames.contains("uploads") {
				S3MockResponse.initiateMultipartUploadResult(uploadID: url.lastPathComponent)
			} else if queryNames.contains("partNumber") {
				"<CopyPartResult><ETag>\"etag\"</ETag></CopyPartResult>"
			} else if queryNames.contains("uploadId") {
				S3MockResponse.completeMultipartUploadResult
			} else {
				S3MockResponse.copyObjectResult
			}
			return try URLProtocolMock.handler(body: body, onRequest: requests.record)(request)
		}
		URLProtocolMock.requestHandler = Array(repeating: answer, count: 12)
		let copyRequests = [
			S3CopyRequest(sourceKey: "large-a", targetKey: "large-a-copy", itemSize: 25),
			S3CopyRequest(sourceKey: "small-a", targetKey: "small-a-copy", itemSize: 5),
			S3CopyRequest(sourceKey: "large-b", targetKey: "large-b-copy", itemSize: 25),
			S3CopyRequest(sourceKey: "small-b", targetKey: "small-b-copy", itemSize: 10)
		]

		try await copyTaskUtility.copy(copyRequests)

		let targets = requests.requests.compactMap { $0.url?.lastPathComponent }
		XCTAssertEqual(["small-a-copy", "small-b-copy"], targets.prefix(2).sorted())
		XCTAssertEqual(Array(repeating: "large-a-copy", count: 5) + Array(repeating: "large-b-copy", count: 5), Array(targets.dropFirst(2)))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// The abort of a cancelled multipart copy is retried after a transient failure, so that no multipart upload is left behind.
	func testCancelledMultipartCopyRetriesAbort() async throws {
		let copyTaskUtility = try S3CopyTaskUtility(client: .mocked(), maxPartSize: 10)
		let abortRequestCount = OSAllocatedUnfairLock(initialState: 0)
		let countAbortRequest: @Sendable (URLRequest) -> Void = { request in
			if request.httpMethod == "DELETE", request.url?.query?.contains("uploadId=upload-id") ?? false {
				abortRequestCount.withLock { $0 += 1 }
			}
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.initiateMultipartUploadResult()),
			URLProtocolMock.handler(statusCode: 503, onRequest: countAbortRequest),
			URLProtocolMock.handler(statusCode: 204, onRequest: countAbortRequest)
		]

		await XCTAssertThrowsErrorAsync(try await value(of: cancelledTask {
			try await copyTaskUtility.copy(S3CopyRequest(sourceKey: "a.txt", targetKey: "b.txt", itemSize: 25))
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}

		XCTAssertEqual(2, abortRequestCount.withLock { $0 })
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	// MARK: - Helpers

	private static func uploadID(of request: URLRequest) -> String? {
		return request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "uploadId" }?.value }
	}
}
