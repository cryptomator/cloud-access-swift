//
//  S3CopyTaskUtilityTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class S3CopyTaskUtilityTests: XCTestCase {
	override func tearDown() {
		URLProtocolMock.requestHandler = []
	}

	/// Each part copies its own range, and the completion lists every part in order with the ETag of its copy.
	func testMultipartCopyCompletesPartsInOrder() async throws {
		let copyTaskUtility = try S3CopyTaskUtility(client: .mocked(), maxPartSize: 10)
		let ranges = OSAllocatedUnfairLock(initialState: [String: String]())
		let completionBody = OSAllocatedUnfairLock<String?>(initialState: nil)
		let partCopy: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) = { request in
			let url = try XCTUnwrap(request.url)
			let partNumber = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "partNumber" }?.value)
			ranges.withLock { $0[partNumber] = request.value(forHTTPHeaderField: "x-amz-copy-source-range") }
			return try (XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)), Data("<CopyPartResult><ETag>\"etag-\(partNumber)\"</ETag></CopyPartResult>".utf8))
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: "<InitiateMultipartUploadResult><UploadId>upload-id</UploadId></InitiateMultipartUploadResult>"),
			partCopy,
			partCopy,
			partCopy,
			URLProtocolMock.handler(body: "<CompleteMultipartUploadResult><ETag>\"etag\"</ETag></CompleteMultipartUploadResult>", onRequest: { request in
				completionBody.withLock { $0 = String(bytes: URLProtocolMock.body(of: request), encoding: .utf8) }
			})
		]

		try await copyTaskUtility.copy(S3CopyRequest(sourceKey: "a.txt", targetKey: "b.txt", itemSize: 25))

		XCTAssertEqual(["1": "bytes=0-9", "2": "bytes=10-19", "3": "bytes=20-24"], ranges.withLock { $0 })
		let body = try XCTUnwrap(completionBody.withLock { $0 })
		XCTAssertTrue(body.contains("<Part><PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag></Part><Part><PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag></Part><Part><PartNumber>3</PartNumber><ETag>&quot;etag-3&quot;</ETag></Part></CompleteMultipartUpload>"), body)
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
			URLProtocolMock.handler(body: "<InitiateMultipartUploadResult><Bucket>exampleBucket</Bucket><Key>b.txt</Key><UploadId>upload-id</UploadId></InitiateMultipartUploadResult>"),
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
}
