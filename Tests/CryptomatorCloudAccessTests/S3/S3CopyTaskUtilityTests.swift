//
//  S3CopyTaskUtilityTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessTestSupport
import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct S3CopyTaskUtilityTests {
		init() {
			URLProtocolMock.requestHandler = []
		}

		/// Each part copies its own range of the source into the target's upload, and the completion lists every part in order with the ETag of its copy.
		@Test
		func multipartCopyCompletesPartsInOrder() async throws {
			let copyTaskUtility = try S3CopyTaskUtility(client: .mocked(), maxPartSize: 10)
			let requests = RequestRecorder()
			let ranges = OSAllocatedUnfairLock(initialState: [String: String]())
			let partCopy: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) = { request in
				requests.record(request)
				let url = try #require(request.url)
				let partNumber = try #require(try URLProtocolMock.queryParameter("partNumber", of: request))
				ranges.withLock { $0[partNumber] = request.value(forHTTPHeaderField: "x-amz-copy-source-range") }
				return try (#require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)), Data("<CopyPartResult><ETag>\"etag-\(partNumber)\"</ETag></CopyPartResult>".utf8))
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: S3MockResponse.initiateMultipartUploadResult(uploadID: "copy-upload-id"), onRequest: requests.record),
				partCopy,
				partCopy,
				partCopy,
				URLProtocolMock.handler(body: S3MockResponse.completeMultipartUploadResult, onRequest: requests.record)
			]

			try await copyTaskUtility.copy(S3CopyRequest(sourceKey: "a.txt", targetKey: "b.txt", itemSize: 25))

			#expect(ranges.withLock { $0 } == ["1": "bytes=0-9", "2": "bytes=10-19", "3": "bytes=20-24"])
			let sent = requests.requests
			#expect(Array(repeating: "/exampleBucket/b.txt", count: 5) == sent.map { $0.url?.path })
			#expect(try Array(repeating: "copy-upload-id", count: 4) == sent.dropFirst().map { try URLProtocolMock.queryParameter("uploadId", of: $0) })
			#expect(Array(repeating: "exampleBucket/a.txt", count: 3) == sent[1 ... 3].map { $0.value(forHTTPHeaderField: "x-amz-copy-source") })
			let body = try #require(sent.last?.httpBody.flatMap { String(bytes: $0, encoding: .utf8) })
			#expect(body.contains("<Part><PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag></Part><Part><PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag></Part><Part><PartNumber>3</PartNumber><ETag>&quot;etag-3&quot;</ETag></Part></CompleteMultipartUpload>"), "\(body)")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The objects that fit in one request are copied before the multipart copies, which run one after another, so that the parts of several objects never add up beyond `concurrencyLimit` requests in flight.
		@Test
		func multipartCopiesRunAfterRegularCopiesOneAtATime() async throws {
			let copyTaskUtility = try S3CopyTaskUtility(client: .mocked(), maxPartSize: 10)
			let requests = RequestRecorder()
			let answer: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) = { request in
				let url = try #require(request.url)
				let parameters = try URLProtocolMock.queryParameters(of: request)
				let body = if parameters.keys.contains("uploads") {
					S3MockResponse.initiateMultipartUploadResult(uploadID: url.lastPathComponent)
				} else if parameters.keys.contains("partNumber") {
					"<CopyPartResult><ETag>\"etag\"</ETag></CopyPartResult>"
				} else if parameters.keys.contains("uploadId") {
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
			#expect(targets.prefix(2).sorted() == ["small-a-copy", "small-b-copy"])
			#expect(Array(repeating: "large-a-copy", count: 5) + Array(repeating: "large-b-copy", count: 5) == Array(targets.dropFirst(2)))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The abort of a cancelled multipart copy is retried after a transient failure, so that no multipart upload is left behind.
		@Test
		func cancelledMultipartCopyRetriesAbort() async throws {
			let copyTaskUtility = try S3CopyTaskUtility(client: .mocked(), maxPartSize: 10)
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: S3MockResponse.initiateMultipartUploadResult()),
				URLProtocolMock.handler(statusCode: 503, onRequest: requests.record),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: cancelledTask {
					try await copyTaskUtility.copy(S3CopyRequest(sourceKey: "a.txt", targetKey: "b.txt", itemSize: 25))
				})
			}

			#expect(try requests.requests.map { try [$0.httpMethod, URLProtocolMock.queryParameter("uploadId", of: $0)] } == [["DELETE", "upload-id"], ["DELETE", "upload-id"]])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}
	}
}
