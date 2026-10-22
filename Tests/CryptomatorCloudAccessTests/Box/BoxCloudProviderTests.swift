//
//  BoxCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
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

class BoxCloudProviderTests: XCTestCase {
	private static let rootWithFile = BoxMockResponse.items([BoxMockResponse.fileEntry(id: "5", name: "file.txt")])
	private static let rootWithFolder = BoxMockResponse.items([BoxMockResponse.folderEntry(id: "3", name: "folder")])
	private static let emptyRoot = BoxMockResponse.items([])
	private static let uploadSession = #"{"id":"S","part_size":4,"session_endpoints":{"upload_part":"https://upload.box.com/api/2.0/files/upload_sessions/S","commit":"https://upload.box.com/api/2.0/files/upload_sessions/S/commit"}}"#

	private var provider: BoxCloudProvider!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max)
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(provider)
	}

	// MARK: - Metadata and Listings

	func testFetchItemMetadataOfFileAndFolder() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
			URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "file.txt")),
			URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder),
			URLProtocolMock.handler(body: BoxMockResponse.folderEntry(id: "3", name: "folder"))
		]

		let file = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))
		let folder = try await provider.fetchItemMetadata(at: CloudPath("/folder"))

		XCTAssertEqual(CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: BoxJSON.date(fromBoxDateTime: BoxMockResponse.modifiedAt), size: 7), file)
		XCTAssertEqual(CloudItemMetadata(name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, lastModifiedDate: nil, size: nil), folder)
	}

	func testPathResolutionSkipsWebLinkOfSameName() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: BoxMockResponse.items([#"{"type":"web_link","id":"9","name":"file.txt"}"#, BoxMockResponse.fileEntry(id: "5", name: "file.txt")])),
			URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "file.txt"))
		]

		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(7, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFetchItemListConvertsEntriesAndReturnsNextMarker() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: BoxMockResponse.items([BoxMockResponse.folderEntry(id: "3", name: "folder"), BoxMockResponse.fileEntry(id: "5", name: "file.txt")], nextMarker: "MARKER"))]

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

		XCTAssertEqual([
			CloudItemMetadata(name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: BoxJSON.date(fromBoxDateTime: BoxMockResponse.modifiedAt), size: 7)
		], itemList.items)
		XCTAssertEqual("MARKER", itemList.nextPageToken)
	}

	func testFetchItemListErrors() async throws {
		let cases = [
			ListingErrorCase(name: "invalid marker", response: URLProtocolMock.handler(statusCode: 400), expectedError: CloudProviderError.pageTokenInvalid),
			ListingErrorCase(name: "web link", response: URLProtocolMock.handler(body: BoxMockResponse.items([#"{"type":"web_link","id":"9","name":"Link"}"#])), expectedError: BoxError.unexpectedContent),
			ListingErrorCase(name: "unparseable date", response: URLProtocolMock.handler(body: BoxMockResponse.items([BoxMockResponse.fileEntry(id: "5", name: "file.txt", modifiedAt: "not-a-date")])), expectedError: BoxError.unexpectedContent)
		]
		for testCase in cases {
			URLProtocolMock.requestHandler = [testCase.response]

			await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "MARKER"), testCase.name) { error in
				XCTAssertEqual(String(describing: testCase.expectedError), String(describing: error), testCase.name)
			}
		}
	}

	/// A 400 on the first page is a bad request, which a restart of the listing wouldn't heal.
	func testFirstPageBadRequestIsNotPageTokenInvalid() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400)]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)) { error in
			XCTAssertEqual(.apiError(statusCode: 400, code: nil, message: nil), error as? BoxError)
		}
	}

	// MARK: - Mutations

	func testCreateFolderPostsNameAndParent() async throws {
		let sentRequest = OSAllocatedUnfairLock<(request: URLRequest, body: Data)?>(initialState: nil)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
			URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.folderEntry(id: "3", name: "folder"), onRequest: { request in
				sentRequest.withLock { $0 = (request, URLProtocolMock.body(of: request)) }
			})
		]

		try await provider.createFolder(at: CloudPath("/folder"))

		let (request, body) = try XCTUnwrap(sentRequest.withLock { $0 })
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual("https://api.box.com/2.0/folders", request.url?.absoluteString)
		XCTAssertEqual(["name": "folder", "parent": ["id": "0"]] as NSDictionary, try JSONSerialization.jsonObject(with: body) as? NSDictionary)
	}

	func testDeleteMissingFileThrowsItemNotFound() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
			URLProtocolMock.handler(statusCode: 404, body: BoxMockResponse.error(status: 404, code: "not_found"))
		]

		await XCTAssertThrowsErrorAsync(try await provider.deleteFile(at: CloudPath("/file.txt"))) { error in
			XCTAssertEqual(.itemNotFound, error as? CloudProviderError)
		}
	}

	func testMoveFilePutsNameAndParent() async throws {
		let sentRequest = OSAllocatedUnfairLock<(request: URLRequest, body: Data)?>(initialState: nil)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
			URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
			URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "renamed.txt"), onRequest: { request in
				sentRequest.withLock { $0 = (request, URLProtocolMock.body(of: request)) }
			})
		]

		try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))

		let (request, body) = try XCTUnwrap(sentRequest.withLock { $0 })
		XCTAssertEqual("PUT", request.httpMethod)
		XCTAssertEqual("https://api.box.com/2.0/files/5", request.url?.absoluteString)
		XCTAssertEqual(["name": "renamed.txt", "parent": ["id": "0"]] as NSDictionary, try JSONSerialization.jsonObject(with: body) as? NSDictionary)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// A mutation's request is its commit point, so it runs with its retries also if the task is cancelled during the first attempt.
	func testCancelledMutationsStillFinishTheirRequests() async throws {
		let localURL = try makeLocalFile(content: "0123456789")
		let cases = [
			MutationCase(name: "create folder", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot)], success: URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.folderEntry(id: "3", name: "folder"))) { provider in
				try await provider.createFolder(at: CloudPath("/folder"))
			},
			MutationCase(name: "delete file", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile)], success: URLProtocolMock.handler(statusCode: 204)) { provider in
				try await provider.deleteFile(at: CloudPath("/file.txt"))
			},
			MutationCase(name: "delete folder", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder)], success: URLProtocolMock.handler(statusCode: 204)) { provider in
				try await provider.deleteFolder(at: CloudPath("/folder"))
			},
			MutationCase(name: "move file", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile), URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile)], success: URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "renamed.txt"))) { provider in
				try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))
			},
			MutationCase(name: "move folder", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder), URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder)], success: URLProtocolMock.handler(body: BoxMockResponse.folderEntry(id: "3", name: "renamed"))) { provider in
				try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed"))
			},
			MutationCase(name: "commit", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot), URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession)] + (0 ..< 3).map { index in URLProtocolMock.handler(body: #"{"part":{"part_id":"P\#(index)"}}"#) }, success: URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]))) { provider in
				_ = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
			}
		]
		for mutationCase in cases {
			let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
			let mutation = OSAllocatedUnfairLock<Task<Void, Error>?>(initialState: nil)
			let started = XCTestExpectation(description: "\(mutationCase.name) started")
			URLProtocolMock.requestHandler = mutationCase.preparation + [
				URLProtocolMock.handler(statusCode: 503, onRequest: { _ in
					mutation.withLock { $0 }?.cancel()
				}),
				mutationCase.success
			]

			let task = Task {
				_ = await XCTWaiter().fulfillment(of: [started], timeout: testWaitTimeout)
				try await mutationCase.operation(provider)
			}
			mutation.withLock { $0 = task }
			started.fulfill()

			try await value(of: task)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty, mutationCase.name)
		}
	}

	// MARK: - Downloads

	func testDownloadWaitsWhileFileIsNotReady() async throws {
		let localURL = tmpDirURL.appendingPathComponent("download.txt")
		let taskCount = OSAllocatedUnfairLock(initialState: 0)
		URLProtocolMock.requestHandler = downloadPreparation() + [
			URLProtocolMock.handler(statusCode: 202, body: "PENDING", headerFields: ["Retry-After": "0"]),
			URLProtocolMock.handler(body: "content")
		]

		let metadata = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: { _ in
			taskCount.withLock { $0 += 1 }
		})

		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: localURL))
		XCTAssertEqual(7, metadata.size)
		XCTAssertEqual(1, taskCount.withLock { $0 })
	}

	func testDownloadThatStaysNotReadyThrowsAndLeavesNoFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent("download.txt")
		URLProtocolMock.requestHandler = downloadPreparation() + Array(repeating: URLProtocolMock.handler(statusCode: 202, body: "PENDING", headerFields: ["Retry-After": "0"]), count: 5)

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.fileNotReady, error as? BoxError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadReportsBytesOfTask() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try BoxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max)
		URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

		let recordedFractions = fractions.withLock { $0 }
		XCTAssertEqual(1, recordedFractions.count)
		XCTAssertGreaterThan(recordedFractions.first ?? 0, 0.5)
		XCTAssertLessThan(recordedFractions.first ?? 1, 1)
	}

	/// Each attempt adds the progress of its task, so a retry takes half of the transfer's share instead of pushing it past complete.
	func testRetriedDownloadSharesProgressWithFirstAttempt() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let fractionAtRetry = OSAllocatedUnfairLock<Double?>(initialState: nil)
		let provider = try BoxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max)
		URLProtocolMock.requestHandler = downloadPreparation() + [
			URLProtocolMock.handler(statusCode: 202, body: "PENDING", headerFields: ["Retry-After": "0", "Content-Length": "7"]),
			URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"], onRequest: { _ in
				fractionAtRetry.withLock { $0 = progress.fractionCompleted }
			})
		]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

		let recordedFractions = fractions.withLock { $0 }
		XCTAssertEqual(2, recordedFractions.count)
		let fractionAfterFirstAttempt = try XCTUnwrap(recordedFractions.first)
		XCTAssertGreaterThan(fractionAfterFirstAttempt, 0.5)
		XCTAssertEqual(fractionAfterFirstAttempt / 2, try XCTUnwrap(fractionAtRetry.withLock { $0 }), accuracy: 0.01)
		XCTAssertEqual(fractionAfterFirstAttempt, try XCTUnwrap(recordedFractions.last), accuracy: 0.01)
	}

	// MARK: - Uploads

	func testSmallUploadSendsMultipartBodyAndHandsOverTaskOnce() async throws {
		let localURL = try makeLocalFile(content: "file content")
		let sentBodies = OSAllocatedUnfairLock(initialState: [(contentType: String?, body: Data)]())
		let recordBody: @Sendable (URLRequest) -> Void = { request in
			sentBodies.withLock { $0.append((request.value(forHTTPHeaderField: "Content-Type"), URLProtocolMock.body(of: request))) }
		}
		let taskCount = OSAllocatedUnfairLock(initialState: 0)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
			URLProtocolMock.handler(statusCode: 503, onRequest: recordBody),
			URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 12)]), onRequest: recordBody)
		]

		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
			taskCount.withLock { $0 += 1 }
		})

		XCTAssertEqual(12, metadata.size)
		XCTAssertEqual(1, taskCount.withLock { $0 })
		let (contentType, body) = try XCTUnwrap(sentBodies.withLock { $0 }.last)
		let boundary = try XCTUnwrap(contentType?.components(separatedBy: "boundary=").last)
		let expectedPrefix = "--\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n"
		let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
		XCTAssertTrue(bodyString.hasPrefix(expectedPrefix), bodyString)
		XCTAssertTrue(bodyString.hasSuffix("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\nfile content\r\n--\(boundary)--\r\n"), bodyString)
		let attributes = try XCTUnwrap(bodyString.dropFirst(expectedPrefix.count).components(separatedBy: "\r\n").first)
		XCTAssertEqual(["name": "file.txt", "parent": ["id": "0"]] as NSDictionary, try JSONSerialization.jsonObject(with: Data(attributes.utf8)) as? NSDictionary)
	}

	func testUploadErrors() async throws {
		let localURL = try makeLocalFile(content: "file content")
		let cases: [(code: String, expectedError: CloudProviderError)] = [
			("storage_limit_exceeded", .quotaInsufficient),
			("access_denied_insufficient_permissions", .unauthorized)
		]
		for (code, expectedError) in cases {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 403, body: BoxMockResponse.error(status: 403, code: code))
			]

			await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil), code) { error in
				XCTAssertEqual(expectedError, error as? CloudProviderError, code)
			}
		}
	}

	func testChunkedUploadSendsPartsWithDigestsAndCommits() async throws {
		let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
		let content = "0123456789"
		let localURL = try makeLocalFile(content: content)
		let partRequests = OSAllocatedUnfairLock(initialState: [(request: URLRequest, body: Data)]())
		let recordPart: @Sendable (URLRequest) -> Void = { request in
			partRequests.withLock { $0.append((request, URLProtocolMock.body(of: request))) }
		}
		let commitRequest = OSAllocatedUnfairLock<(request: URLRequest, body: Data)?>(initialState: nil)
		let taskCount = OSAllocatedUnfairLock(initialState: 0)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
			URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession)
		] + (0 ..< 3).map { index in
			URLProtocolMock.handler(body: #"{"part":{"part_id":"P\#(index)","offset":\#(index * 4),"size":\#(min(4, 10 - index * 4)),"sha1":"H\#(index)"}}"#, onRequest: recordPart)
		} + [
			URLProtocolMock.handler(statusCode: 202, headerFields: ["Retry-After": "0"]),
			URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]), onRequest: { request in
				commitRequest.withLock { $0 = (request, URLProtocolMock.body(of: request)) }
			})
		]

		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
			taskCount.withLock { $0 += 1 }
		})

		XCTAssertEqual(10, metadata.size)
		XCTAssertEqual(0, taskCount.withLock { $0 })
		let parts = partRequests.withLock { $0 }
		XCTAssertEqual(["bytes 0-3/10", "bytes 4-7/10", "bytes 8-9/10"], parts.map { $0.request.value(forHTTPHeaderField: "content-range") })
		XCTAssertEqual(["0123", "4567", "89"].map { BoxCloudProviderTests.digest(of: $0) }, parts.map { $0.request.value(forHTTPHeaderField: "digest") })
		XCTAssertEqual(["0123", "4567", "89"], parts.map { String(data: $0.body, encoding: .utf8) })
		XCTAssertEqual(["PUT", "PUT", "PUT"], parts.map(\.request.httpMethod))
		let (request, body) = try XCTUnwrap(commitRequest.withLock { $0 })
		XCTAssertEqual("https://upload.box.com/api/2.0/files/upload_sessions/S/commit", request.url?.absoluteString)
		XCTAssertEqual(BoxCloudProviderTests.digest(of: content), request.value(forHTTPHeaderField: "digest"))
		let commitParts = try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["parts"] as? [[String: Any]])
		XCTAssertEqual(["P0", "P1", "P2"], commitParts.map { $0["part_id"] as? String })
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testChunkedUploadOfExistingFileCreatesSessionForFile() async throws {
		let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
		let sessionRequest = OSAllocatedUnfairLock<(request: URLRequest, body: Data)?>(initialState: nil)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
			URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession, onRequest: { request in
				sessionRequest.withLock { $0 = (request, URLProtocolMock.body(of: request)) }
			})
		] + (0 ..< 3).map { index in
			URLProtocolMock.handler(body: #"{"part":{"part_id":"P\#(index)"}}"#)
		} + [URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]))]

		let metadata = try await provider.uploadFile(from: makeLocalFile(content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil)

		XCTAssertEqual(10, metadata.size)
		let (request, body) = try XCTUnwrap(sessionRequest.withLock { $0 })
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual("https://upload.box.com/api/2.0/files/5/upload_sessions", request.url?.absoluteString)
		XCTAssertEqual(["file_size": 10] as NSDictionary, try JSONSerialization.jsonObject(with: body) as? NSDictionary)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testChunkedUploadReportsBytesOfParts() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try BoxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max, chunkedUploadThreshold: 10)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
			URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession)
		] + (0 ..< 3).map { index in
			URLProtocolMock.handler(body: #"{"part":{"part_id":"P\#(index)"}}"#)
		} + [URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]))]

		_ = try await provider.uploadFile(from: makeLocalFile(content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

		let recordedFractions = fractions.withLock { $0 }
		XCTAssertEqual(3, recordedFractions.count)
		for (index, (fraction, (bytesBefore, partLength))) in zip(recordedFractions, [(0.0, 4.0), (4.0, 4.0), (8.0, 2.0)]).enumerated() {
			XCTAssertGreaterThan(fraction, (bytesBefore + partLength / 2) / 10, "part \(index)")
			XCTAssertLessThan(fraction, 1, "part \(index)")
		}
	}

	func testCancellationBeforePartStopsChunkedUpload() async throws {
		let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
		let localURL = try makeLocalFile(content: "0123456789")
		let upload = OSAllocatedUnfairLock<Task<CloudItemMetadata, Error>?>(initialState: nil)
		let started = XCTestExpectation(description: "upload started")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
			URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession),
			URLProtocolMock.handler(body: #"{"part":{"part_id":"P0"}}"#, onRequest: { _ in
				upload.withLock { $0 }?.cancel()
			}),
			URLProtocolMock.handler(body: #"{"part":{"part_id":"P1"}}"#)
		]

		let task = Task {
			_ = await XCTWaiter().fulfillment(of: [started], timeout: testWaitTimeout)
			return try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
		}
		upload.withLock { $0 = task }
		started.fulfill()

		await XCTAssertThrowsErrorAsync(try await value(of: task)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	// MARK: - Helpers

	private static func digest(of string: String) -> String {
		return "sha=\(Data(Insecure.SHA1.hash(data: Data(string.utf8))).base64EncodedString())"
	}

	/// The listing and the metadata request that precede the download of `/file.txt`.
	private func downloadPreparation() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
		return [
			URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
			URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "file.txt"))
		]
	}

	private func makeLocalFile(content: String) throws -> URL {
		let localURL = tmpDirURL.appendingPathComponent("local.txt")
		try Data(content.utf8).write(to: localURL)
		return localURL
	}
}

private struct ListingErrorCase {
	let name: String
	let response: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let expectedError: Error
}

private struct MutationCase {
	let name: String
	/// The responses to the requests before the mutation's request.
	let preparation: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)]
	/// The response to the retry of the mutation's request.
	let success: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let operation: @Sendable (BoxCloudProvider) async throws -> Void
}
