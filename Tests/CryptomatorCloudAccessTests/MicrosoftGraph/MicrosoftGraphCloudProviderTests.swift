//
//  MicrosoftGraphCloudProviderTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 26.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class MicrosoftGraphCloudProviderTests: XCTestCase {
	private static let fileItem = #"{"id":"F","name":"file.txt","size":7,"file":{}}"#

	var provider: MicrosoftGraphCloudProvider!
	let maxPageSize = 100
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		provider = try MicrosoftGraphCloudProvider(client: .mocked(), maxPageSize: maxPageSize)
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

	func testConvertStandardError() {
		let cancellationError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
		XCTAssertTrue(provider.convertStandardError(cancellationError) is CancellationError)
		XCTAssertTrue(provider.convertStandardError(NSError(domain: "Test", code: 0, userInfo: [NSUnderlyingErrorKey: cancellationError])) is CancellationError)
		XCTAssertEqual(.noInternetConnection, provider.convertStandardError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) as? CloudProviderError)
	}

	func testUploadSessionURLIsNotLogged() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		let localURL = try makeLocalFile(content: "content")
		let folderBody = "{\"id\":\"FolderIdentifier\",\"name\":\"folder\",\"folder\":{}}"
		URLProtocolMock.requestHandler = [
			{ request in (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(folderBody.utf8)) },
			{ request in (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil) },
			{ request in (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"uploadUrl\":\"https://upload.example.com/up/SECRET-PATH-TOKEN?tempauth=SECRET-TEMPAUTH\"}".utf8)) },
			{ request in (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data("{\"id\":\"FileIdentifier\",\"name\":\"file.txt\",\"size\":7}".utf8)) }
		]

		_ = try await provider.uploadFile(from: localURL, to: CloudPath("/folder/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		XCTAssertFalse(logCapture.joinedMessages.contains("SECRET"))
		XCTAssertTrue(logCapture.messages.contains { $0.hasPrefix("--> PUT https://upload.example.com") })
	}

	// MARK: - Listings

	func testPageTokenOutsideGraphIsInvalidWithoutRequest() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"value":[]}"#)]

		for pageToken in ["https://evil.example/v1.0/me/drive/items/D/children?$skiptoken=X", "http://graph.microsoft.com/v1.0/me/drive/items/D/children", "https://graph.microsoft.com.evil.example/v1.0", "not a URL"] {
			await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: pageToken), pageToken) { error in
				XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError, pageToken)
			}
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testBadRequestForPageTokenIsPageTokenInvalid() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400)]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "https://graph.microsoft.com/v1.0/me/drive/items/D/children?$skiptoken=STALE")) { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}
	}

	/// A page of 1000 items without `$select` is about 1.5 MB, which the metadata body limit must allow.
	func testFullPageOfChildrenIsListed() async throws {
		let padding = String(repeating: "x", count: 1360)
		let items = (0 ..< 1000).map { #"{"id":"ID\#($0)","name":"file\#($0).txt","size":7,"file":{"mimeType":"text/plain"},"description":"\#(padding)"}"# }
		let body = #"{"value":[\#(items.joined(separator: ","))]}"#
		XCTAssertGreaterThan(body.utf8.count, 1_400_000)
		let provider = try MicrosoftGraphCloudProvider(client: .mocked(), maxPageSize: 1000)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: body)]

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

		XCTAssertEqual(1000, itemList.items.count)
	}

	// MARK: - Transfers

	func testDownloadAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: MicrosoftGraphCloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", onRequest: { _ in
			XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
		})]

		let metadata = try await value(of: Task {
			try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		})

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: localURL))
		XCTAssertEqual(7, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: MicrosoftGraphCloudProvider = provider
		let localURL = try makeLocalFile(content: "content")
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: { _ in
			XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
		})]

		let metadata = try await value(of: Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		})

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(7, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadWithCancellationDuringOnTaskCreation() async throws {
		let provider: MicrosoftGraphCloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content")]

		let download = Task {
			try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}

		XCTAssertEqual(1, URLProtocolMock.requestHandler.count, "The task of a cancelled download must not be resumed")
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testUploadWithCancellationDuringOnTaskCreation() async throws {
		let provider: MicrosoftGraphCloudProvider = provider
		let localURL = try makeLocalFile(content: "content")
		URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem)]

		let upload = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}

		XCTAssertEqual(1, URLProtocolMock.requestHandler.count, "The task of a cancelled upload must not be resumed")
	}

	func testUploadOfSeveralChunksSendsEachChunkOnceAndHandsOverNoTask() async throws {
		let chunkLength = 5 * 1024 * 1024
		let content = Data((0 ..< chunkLength * 3 / 2).map { UInt8($0 % 251) })
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		try content.write(to: localURL)
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
		let chunks = OSAllocatedUnfairLock(initialState: [(range: String?, body: Data)]())
		let fractionBeforeSecondChunk = OSAllocatedUnfairLock<Double?>(initialState: nil)
		let recordChunk: @Sendable (URLRequest) -> Void = { request in
			chunks.withLock { $0.append((request.value(forHTTPHeaderField: "Content-Range"), URLProtocolMock.body(of: request))) }
		}
		let taskCount = OSAllocatedUnfairLock(initialState: 0)
		URLProtocolMock.requestHandler = uploadPreparation() + [
			URLProtocolMock.handler(statusCode: 202, body: "{}", onRequest: recordChunk),
			URLProtocolMock.handler(statusCode: 201, body: #"{"id":"F","name":"file.txt","size":7864320,"file":{}}"#, onRequest: { request in
				fractionBeforeSecondChunk.withLock { $0 = progress.fractionCompleted }
				recordChunk(request)
			})
		]

		_ = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: { _ in
			taskCount.withLock { $0 += 1 }
		})

		let sentChunks = chunks.withLock { $0 }
		XCTAssertEqual(["bytes 0-5242879/7864320", "bytes 5242880-7864319/7864320"], sentChunks.map(\.range))
		XCTAssertEqual([content.prefix(chunkLength), content.suffix(from: chunkLength)], sentChunks.map(\.body))
		// The first chunk holds two thirds of the bytes.
		XCTAssertEqual(0.999 * 2 / 3, try XCTUnwrap(fractionBeforeSecondChunk.withLock { $0 }), accuracy: 0.001)
		// The last chunk holds the remaining third, so the upload's share isn't exceeded.
		XCTAssertEqual(0.999, try XCTUnwrap(fractions.withLock { $0 }.last), accuracy: 0.001)
		XCTAssertEqual(0, taskCount.withLock { $0 })
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadReportsBytesOfTask() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
		URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

		assertTransferProgress(fractions.withLock { $0 })
	}

	func testUploadReportsBytesOfTask() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
		URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem)]

		_ = try await provider.uploadFile(from: makeLocalFile(content: "content"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

		assertTransferProgress(fractions.withLock { $0 })
	}

	// MARK: - Requests

	func testChildrenRequest() throws {
		let item = MicrosoftGraphItem(cloudPath: CloudPath("/test"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let request = try provider.childrenRequest(for: item)
		XCTAssertEqual("GET", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/children?$top=100"), request.url)
		XCTAssertNil(request.httpBody)
	}

	func testContentRequest() throws {
		let item = MicrosoftGraphItem(cloudPath: CloudPath("/test"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let request = try provider.contentRequest(for: item)
		XCTAssertEqual("GET", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/content"), request.url)
		XCTAssertNil(request.httpBody)
	}

	func testCreateUploadSessionRequest() throws {
		let parentItem = MicrosoftGraphItem(cloudPath: CloudPath("/testFolder"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let request = try provider.createUploadSessionRequest(for: parentItem, with: "Test.txt")
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier:/Test.txt:/createUploadSession"), request.url)
		XCTAssertNil(request.httpBody)
	}

	func testFileChunkUploadRequest() throws {
		let uploadURL = try XCTUnwrap(URL(string: "example.com"))
		let chunkLength = 26
		let totalLength = 128
		let request = provider.fileChunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: 0, totalLength: totalLength)
		XCTAssertEqual("PUT", request.httpMethod)
		XCTAssertEqual("26", request.value(forHTTPHeaderField: "Content-Length"))
		XCTAssertEqual("bytes 0-25/128", request.value(forHTTPHeaderField: "Content-Range"))
		XCTAssertEqual(uploadURL, request.url)
	}

	func testFileChunkUploadRequestWithOffset() throws {
		let uploadURL = try XCTUnwrap(URL(string: "example.com"))
		let chunkLength = 26
		let totalLength = 128
		let request = provider.fileChunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: 26, totalLength: totalLength)
		XCTAssertEqual("PUT", request.httpMethod)
		XCTAssertEqual("26", request.value(forHTTPHeaderField: "Content-Length"))
		XCTAssertEqual("bytes 26-51/128", request.value(forHTTPHeaderField: "Content-Range"))
		XCTAssertEqual(uploadURL, request.url)
	}

	func testCreateFolderRequest() throws {
		let parentItem = MicrosoftGraphItem(cloudPath: CloudPath("/testFolder"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let expectedRequestBody = "{\"@odata.type\":\"#microsoft.graph.driveItem\",\"folder\":{},\"name\":\"subFolder\"}"
		let request = try provider.createFolderRequest(for: parentItem, with: "subFolder")
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/children"), request.url)
		XCTAssertEqual(expectedRequestBody.data(using: .utf8), request.httpBody)
	}

	func testDeleteItemRequest() throws {
		let item = MicrosoftGraphItem(cloudPath: CloudPath("/test.txt"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .file)
		let request = try provider.deleteItemRequest(for: item)
		XCTAssertEqual("DELETE", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier"), request.url)
		XCTAssertNil(request.httpBody)
	}

	func testMoveItemRequest() throws {
		let item = MicrosoftGraphItem(cloudPath: CloudPath("/test.txt"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .file)
		let newParentItem = MicrosoftGraphItem(cloudPath: CloudPath("/Folder"), identifier: "TestIdentifier-Folder", driveIdentifier: nil, itemType: .folder)
		let targetCloudPath = CloudPath("/Folder/test.txt")
		let expectedRequestBody = "{\"@odata.type\":\"#microsoft.graph.driveItem\",\"name\":\"test.txt\",\"parentReference\":{\"id\":\"TestIdentifier-Folder\"}}"
		let request = try provider.moveItemRequest(for: item, with: newParentItem, targetCloudPath: targetCloudPath)
		XCTAssertEqual("PATCH", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier"), request.url)
		XCTAssertEqual(expectedRequestBody.data(using: .utf8), request.httpBody)
	}

	// MARK: - Helpers

	/// The responses of the path lookup and the metadata request of `/file.txt`, before its download.
	private func downloadPreparation() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
		return [URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem), URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem)]
	}

	/// The responses of the lookup that finds no `/file.txt` and of the upload session request, before the upload's `PUT`.
	private func uploadPreparation() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
		return [URLProtocolMock.handler(statusCode: 404), URLProtocolMock.handler(body: #"{"uploadUrl":"https://upload.example.com/up/TOKEN"}"#)]
	}

	private func makeLocalFile(content: String) throws -> URL {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		try Data(content.utf8).write(to: localURL)
		return localURL
	}

	private func assertTransferProgress(_ fractions: [Double], file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertEqual(1, fractions.count, "Unexpected number of transfer tasks", file: file, line: line)
		XCTAssertGreaterThan(fractions.first ?? 0, 0.5, "The progress of the transfer task isn't part of the transfer's progress", file: file, line: line)
		XCTAssertLessThan(fractions.first ?? 1, 1, "The progress completed before the transfer returned", file: file, line: line)
	}
}
