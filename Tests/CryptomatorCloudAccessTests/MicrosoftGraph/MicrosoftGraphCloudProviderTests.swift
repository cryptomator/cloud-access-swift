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
@testable import CryptomatorCloudAccessCore

class MicrosoftGraphCloudProviderTests: XCTestCase {
	private static let fileItem = #"{"id":"F","name":"file.txt","size":7,"file":{}}"#
	private static let downloadURL = "https://content.example.com/dl/SECRET-PATH?tempauth=SECRET"
	private static let fileItemWithDownloadURL = #"{"id":"F","name":"file.txt","size":7,"file":{},"fileSystemInfo":{"lastModifiedDateTime":"2026-11-16T10:00:00Z"},"@microsoft.graph.downloadUrl":"\#(MicrosoftGraphCloudProviderTests.downloadURL)"}"#

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

	/// An item whose name is no single path component is neither listed nor cached, so that it shadows no path and doesn't replace the cached root.
	func testListingSkipsNamesThatAreNoSinglePathComponent() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: #"{"value":[{"id":"X1","name":".","folder":{}},{"id":"X2","name":"a/b","size":7,"file":{}},\#(MicrosoftGraphCloudProviderTests.fileItem)],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/drive/items/root/children?$skiptoken=NEXT"}"#),
			URLProtocolMock.handler(statusCode: 404, onRequest: requests.record)
		]

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/a/b")))

		XCTAssertEqual([CloudPath("/file.txt")], itemList.items.map(\.cloudPath))
		XCTAssertEqual("https://graph.microsoft.com/v1.0/me/drive/items/root/children?$skiptoken=NEXT", itemList.nextPageToken)
		XCTAssertEqual([URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/root:/a:?$select=id,name,size,folder,fileSystemInfo,parentReference,remoteItem")], requests.requests.map(\.url))
		XCTAssertEqual(2, logCapture.messages.count(where: { $0.hasSuffix("because its name is no single path component") }))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testListingOfItemWithoutNameThrowsMissingItemName() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"value":[{"id":"F","size":7,"file":{}}]}"#)]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)) { error in
			guard case MicrosoftGraphError.missingItemName = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	// MARK: - Metadata

	func testItemMetadataSelectsFields() async throws {
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record),
			URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record)
		]

		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

		XCTAssertEqual(7, metadata.size)
		XCTAssertEqual([
			URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/root:/file.txt:?$select=id,name,size,folder,fileSystemInfo,parentReference,remoteItem"),
			URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/F?$select=id,name,size,folder,fileSystemInfo,parentReference,remoteItem")
		], requests.requests.map(\.url))
	}

	/// An inaccessible item answers 403, which signing in again wouldn't fix.
	func testForbiddenItemThrowsRawError() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 403)]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))) { error in
			guard case MicrosoftGraphError.unexpectedHTTPStatusCode(code: 403) = error else {
				return XCTFail("Unexpected error: \(error)")
			}
		}
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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

	/// The upload URL is pre-authenticated, so signing in again can't fix a refused chunk. A 404 concerns the upload session, not the item.
	func testRefusedChunkThrowsErrorOfItsStatus() async throws {
		let cases: [(statusCode: Int, expectedError: Error)] = [
			(401, MicrosoftGraphError.unexpectedHTTPStatusCode(code: 401)),
			(403, MicrosoftGraphError.unexpectedHTTPStatusCode(code: 403)),
			(404, MicrosoftGraphError.unexpectedHTTPStatusCode(code: 404)),
			(507, CloudProviderError.quotaInsufficient)
		]
		let localURL = try makeLocalFile(content: "content")
		for testCase in cases {
			URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: testCase.statusCode)]

			await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil), "\(testCase.statusCode)") { error in
				XCTAssertEqual(String(describing: testCase.expectedError), String(describing: error), "\(testCase.statusCode)")
			}
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty, "\(testCase.statusCode)")
		}
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

	// MARK: - Download URL

	/// The date comes from the metadata request, because the path lookup's item has none.
	func testDownloadFromDownloadURL() async throws {
		let requests = RequestRecorder()
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record),
			URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItemWithDownloadURL, onRequest: requests.record),
			URLProtocolMock.handler(body: "content", onRequest: requests.record)
		]

		let metadata = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)

		XCTAssertEqual([
			URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/root:/file.txt:?$select=id,name,size,folder,fileSystemInfo,parentReference,remoteItem"),
			URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/F"),
			URL(string: MicrosoftGraphCloudProviderTests.downloadURL)
		], requests.requests.map(\.url))
		XCTAssertNil(requests.requests.last?.value(forHTTPHeaderField: "Authorization"))
		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: localURL))
		XCTAssertEqual(Date(timeIntervalSince1970: 1_794_823_200), metadata.lastModifiedDate)
	}

	func testDownloadWithoutUsableDownloadURLGoesThroughGraph() async throws {
		for metadataBody in [MicrosoftGraphCloudProviderTests.fileItem, MicrosoftGraphCloudProviderTests.fileItemWithDownloadURL.replacingOccurrences(of: "https://", with: "http://")] {
			let provider = try MicrosoftGraphCloudProvider(client: .mocked())
			let requests = RequestRecorder()
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem),
				URLProtocolMock.handler(body: metadataBody),
				URLProtocolMock.handler(body: "content", onRequest: requests.record)
			]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)

			XCTAssertEqual([URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/F/content")], requests.requests.map(\.url), metadataBody)
			XCTAssertEqual("Bearer TOKEN", requests.requests.first?.value(forHTTPHeaderField: "Authorization"), metadataBody)
			XCTAssertEqual(Data("content".utf8), try Data(contentsOf: localURL), metadataBody)
		}
	}

	func testRefusedDownloadURLFallsBackToGraph() async throws {
		let requests = RequestRecorder()
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = directDownloadPreparation() + [
			URLProtocolMock.handler(statusCode: 401),
			URLProtocolMock.handler(body: "content", onRequest: requests.record)
		]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)

		XCTAssertEqual([URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/F/content")], requests.requests.map(\.url))
		XCTAssertEqual("Bearer TOKEN", requests.requests.first?.value(forHTTPHeaderField: "Authorization"))
		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: localURL))
	}

	func testDeletedFileThrowsItemNotFoundAfterFallback() async throws {
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(statusCode: 404), URLProtocolMock.handler(statusCode: 404)]

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.itemNotFound, error as? CloudProviderError)
		}
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testOtherSuccessOfDownloadURLFailsWithoutFallback() async throws {
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(statusCode: 206, body: "con"), URLProtocolMock.handler(body: "content")]

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)) { error in
			guard case MicrosoftGraphError.unexpectedHTTPStatusCode(code: 206) = error else {
				return XCTFail("Unexpected error: \(error)")
			}
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testDownloadURLIsNotLogged() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: "content")]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: nil, onTaskCreation: nil)

		XCTAssertTrue(logCapture.messages.contains { $0.hasPrefix("--> GET https://content.example.com") }, logCapture.joinedMessages)
		XCTAssertFalse(logCapture.joinedMessages.contains("SECRET"), logCapture.joinedMessages)
	}

	func testDownloadFromDownloadURLReportsBytesOfTask() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
		URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

		assertTransferProgress(fractions.withLock { $0 })
	}

	func testFallbackHandsOverNoTask() async throws {
		let taskHosts = OSAllocatedUnfairLock(initialState: [String?]())
		URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: "content")]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: nil, onTaskCreation: { task in
			taskHosts.withLock { $0.append(task.originalRequest?.url?.host()) }
		})

		XCTAssertEqual(["content.example.com"], taskHosts.withLock { $0 })
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFallbackReportsProgressOfItsTransfer() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractionBeforeFallback = OSAllocatedUnfairLock<Double?>(initialState: nil)
		let fractionsOfFallback = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks(willProcessCompletion: { task in
			if task is URLSessionDownloadTask, task.originalRequest?.url?.path.hasSuffix("/content") == true {
				fractionsOfFallback.withLock { $0.append(progress.fractionCompleted) }
			}
		})))
		URLProtocolMock.requestHandler = directDownloadPreparation() + [
			URLProtocolMock.handler(statusCode: 401, body: "refused", headerFields: ["Content-Length": "7"]),
			URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"], onRequest: { _ in
				fractionBeforeFallback.withLock { $0 = progress.fractionCompleted }
			})
		]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: progress, onTaskCreation: nil)

		let before = try XCTUnwrap(fractionBeforeFallback.withLock { $0 })
		let fallbackFractions = fractionsOfFallback.withLock { $0 }
		XCTAssertLessThan(before, 0.9, "The refused transfer completed the download's progress")
		XCTAssertEqual(1, fallbackFractions.count)
		XCTAssertGreaterThan(fallbackFractions.first ?? 0, before, "The progress of the fallback's task isn't part of the download's progress")
		XCTAssertLessThan(fallbackFractions.first ?? 1, 1, "The progress completed before the download returned")
	}

	func testCancellationBeforeFallbackStopsDownload() async throws {
		let provider: MicrosoftGraphCloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		let canceller = TaskCanceller<CloudItemMetadata>()
		URLProtocolMock.requestHandler = directDownloadPreparation() + [
			URLProtocolMock.handler(statusCode: 401, onRequest: { _ in
				canceller.cancel()
			}),
			URLProtocolMock.handler(body: "content")
		]

		let download = canceller.start {
			try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)
		}

		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	// MARK: - Requests

	func testChildrenRequest() throws {
		let item = MicrosoftGraphItem(cloudPath: CloudPath("/test"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let request = try provider.childrenRequest(for: item)
		XCTAssertEqual("GET", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/children?$top=100&$select=id,name,size,folder,fileSystemInfo,parentReference,remoteItem"), request.url)
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

	/// The responses of the path lookup and the metadata request of `/file.txt` before its download, the latter carrying a download URL.
	private func directDownloadPreparation() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
		return [URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem), URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItemWithDownloadURL)]
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
