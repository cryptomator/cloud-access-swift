//
//  PCloudCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import GRDB
import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class PCloudCloudProviderTests: XCTestCase {
	private var provider: PCloudCloudProvider!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		provider = try PCloudCloudProvider(client: .mocked())
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

	// MARK: - Error Mapping

	/// An unmapped code, e.g., a connection that broke during an upload, doesn't ask for a new login.
	func testUploadFileWithUnmappedCodeThrowsAPIError() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0)),
			URLProtocolMock.handler(body: PCloudMockResponse.result(2041))
		]

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: makeLocalFile(), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(code: 2041, message: "Error 2041."), error as? PCloudError)
		}
	}

	/// Each API error code that a method maps, scripted after the listings that resolve its paths.
	func testMapsAPIErrorCodesPerMethod() async throws {
		let localURL = try makeLocalFile()
		let downloadURL = tmpDirURL.appendingPathComponent("download.txt")
		let rootWithFolder = PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 3, name: "folder")])
		let rootWithFile = PCloudProviderTestResponse.rootWithFile
		let cases = [
			ProviderCase(name: "stat", responses: [rootWithFile, PCloudMockResponse.result(2009)], operation: { _ = try await $0.fetchItemMetadata(at: CloudPath("/file.txt")) }, expected: CloudProviderError.itemNotFound),
			ProviderCase(name: "listfolder of an upload's parent", responses: [PCloudMockResponse.result(2005)], operation: { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }, expected: CloudProviderError.parentFolderDoesNotExist),
			ProviderCase(name: "listfolder of a folder", responses: [rootWithFolder, PCloudMockResponse.result(2005)], operation: { _ = try await $0.fetchItemMetadata(at: CloudPath("/folder")) }, expected: CloudProviderError.itemNotFound),
			ProviderCase(name: "listfolder of a listing", responses: [rootWithFolder, PCloudMockResponse.result(2005)], operation: { _ = try await $0.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil) }, expected: CloudProviderError.itemNotFound),
			ProviderCase(name: "listfolder of a path", responses: [rootWithFolder, PCloudMockResponse.result(2005)], operation: { _ = try await $0.fetchItemMetadata(at: CloudPath("/folder/file.txt")) }, expected: CloudProviderError.itemNotFound),
			ProviderCase(name: "listfolder of a collision check", responses: [rootWithFolder, PCloudMockResponse.result(2005)], operation: { try await $0.createFolder(at: CloudPath("/folder/sub")) }, expected: CloudProviderError.parentFolderDoesNotExist),
			ProviderCase(name: "getfilelink", responses: [rootWithFile, PCloudMockResponse.file(id: 5), PCloudMockResponse.result(2009)], operation: { _ = try await $0.downloadFile(from: CloudPath("/file.txt"), to: downloadURL, progress: nil, onTaskCreation: nil) }, expected: CloudProviderError.itemNotFound),
			ProviderCase(name: "deletefile", responses: [rootWithFile, PCloudMockResponse.result(2009)], operation: { try await $0.deleteFile(at: CloudPath("/file.txt")) }, expected: CloudProviderError.itemNotFound),
			ProviderCase(name: "deletefolderrecursive", responses: [rootWithFolder, PCloudMockResponse.result(2005)], operation: { try await $0.deleteFolder(at: CloudPath("/folder")) }, expected: CloudProviderError.itemNotFound),
			ProviderCase(name: "createfolder 2004", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.result(2004)], operation: { try await $0.createFolder(at: CloudPath("/folder")) }, expected: CloudProviderError.itemAlreadyExists),
			ProviderCase(name: "createfolder 2002", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.result(2002)], operation: { try await $0.createFolder(at: CloudPath("/folder")) }, expected: CloudProviderError.parentFolderDoesNotExist),
			ProviderCase(name: "createfolder 2008", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.result(2008)], operation: { try await $0.createFolder(at: CloudPath("/folder")) }, expected: CloudProviderError.quotaInsufficient),
			ProviderCase(name: "uploadfile 2005", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.result(2005)], operation: { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }, expected: CloudProviderError.parentFolderDoesNotExist),
			ProviderCase(name: "uploadfile 2008", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.result(2008)], operation: { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }, expected: CloudProviderError.quotaInsufficient),
			ProviderCase(name: "renamefile 2005", responses: [rootWithFile, rootWithFile, PCloudMockResponse.result(2005)], operation: { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) }, expected: CloudProviderError.parentFolderDoesNotExist),
			ProviderCase(name: "renamefile 2009", responses: [rootWithFile, rootWithFile, PCloudMockResponse.result(2009)], operation: { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) }, expected: CloudProviderError.itemNotFound),
			ProviderCase(name: "renamefile 2008", responses: [rootWithFile, rootWithFile, PCloudMockResponse.result(2008)], operation: { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) }, expected: CloudProviderError.quotaInsufficient),
			ProviderCase(name: "renamefolder 2004", responses: [rootWithFolder, rootWithFolder, PCloudMockResponse.result(2004)], operation: { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) }, expected: CloudProviderError.itemAlreadyExists),
			ProviderCase(name: "renamefolder 2005", responses: [rootWithFolder, rootWithFolder, PCloudMockResponse.result(2005)], operation: { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) }, expected: CloudProviderError.itemNotFound),
			ProviderCase(name: "renamefolder 2008", responses: [rootWithFolder, rootWithFolder, PCloudMockResponse.result(2008)], operation: { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) }, expected: CloudProviderError.quotaInsufficient)
		]

		for testCase in cases {
			let provider = try PCloudCloudProvider(client: .mocked())
			URLProtocolMock.requestHandler = testCase.responses.map { URLProtocolMock.handler(body: $0) }

			await XCTAssertThrowsErrorAsync(try await testCase.operation(provider), testCase.name) { error in
				XCTAssertEqual(testCase.expected, error as? CloudProviderError, "\(testCase.name): \(error)")
			}
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty, testCase.name)
		}
	}

	func testFailedDownloadThrowsErrorOfResultAndLeavesNoFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(statusCode: 410, body: PCloudMockResponse.result(2009))]

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(code: 2009, message: "Error 2009."), error as? PCloudError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	// MARK: - Metadata

	func testFetchItemMetadataConvertsFileAndFolder() async throws {
		let root = PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "file.txt"), PCloudMockResponse.folderEntry(id: 3, name: "folder")])
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: root),
			URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5)),
			URLProtocolMock.handler(body: root),
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3))
		]

		let fileMetadata = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))
		let folderMetadata = try await provider.fetchItemMetadata(at: CloudPath("/folder"))

		PCloudProviderTestResponse.assertMetadata(fileMetadata, name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, size: 7)
		PCloudProviderTestResponse.assertMetadata(folderMetadata, name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, size: nil)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFetchItemListConvertsAndCachesChildren() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "file.txt"), PCloudMockResponse.folderEntry(id: 3, name: "folder")])),
			URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5))
		]

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

		XCTAssertEqual(2, itemList.items.count)
		XCTAssertNil(itemList.nextPageToken)
		PCloudProviderTestResponse.assertMetadata(itemList.items[0], name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, size: 7)
		PCloudProviderTestResponse.assertMetadata(itemList.items[1], name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, size: nil)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty, "The listed file was resolved through another listing")
	}

	func testIncompleteMetadataThrowsUnexpectedContent() async throws {
		let cases = [
			ProviderCase(name: "listing without contents", responses: [#"{"result":0,"metadata":{"isfolder":true,"name":"","folderid":0,"modified":1792056600}}"#], operation: { _ = try await $0.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }, expected: PCloudError.unexpectedContent),
			ProviderCase(name: "child without identifier", responses: [#"{"result":0,"metadata":{"isfolder":true,"name":"","folderid":0,"modified":1792056600,"contents":[{"isfolder":false,"name":"file.txt","modified":1792056600,"size":7}]}}"#], operation: { _ = try await $0.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }, expected: PCloudError.unexpectedContent),
			ProviderCase(name: "file without size", responses: [PCloudProviderTestResponse.rootWithFile, #"{"result":0,"metadata":{"isfolder":false,"name":"file.txt","fileid":5,"modified":1792056600}}"#], operation: { _ = try await $0.fetchItemMetadata(at: CloudPath("/file.txt")) }, expected: PCloudError.unexpectedContent)
		]

		for testCase in cases {
			let provider = try PCloudCloudProvider(client: .mocked())
			URLProtocolMock.requestHandler = testCase.responses.map { URLProtocolMock.handler(body: $0) }

			await XCTAssertThrowsErrorAsync(try await testCase.operation(provider), testCase.name) { error in
				XCTAssertEqual(testCase.expected, error as? PCloudError, "\(testCase.name): \(error)")
			}
		}
	}

	func testListingWithNullContentsIsOnlyFolderMetadata() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 3, name: "folder")])),
			URLProtocolMock.handler(body: PCloudProviderTestResponse.folderWithNullContents),
			URLProtocolMock.handler(body: PCloudProviderTestResponse.folderWithNullContents)
		]

		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/folder"))
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)) { error in
			XCTAssertEqual(.unexpectedContent, error as? PCloudError)
		}

		PCloudProviderTestResponse.assertMetadata(metadata, name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, size: nil)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testLooksUpChildByNameWithoutDecodingLaterChildren() async throws {
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 1, name: "a.txt"), PCloudMockResponse.fileEntry(id: 2, name: "b.txt"), #"{"isfolder":false,"name":"c.txt"}"#])),
			URLProtocolMock.handler(body: PCloudMockResponse.file(id: 2, name: "b.txt"), onRequest: requests.record)
		]

		_ = try await provider.fetchItemMetadata(at: CloudPath("/b.txt"))

		XCTAssertEqual("2", requests.requests.first.map(URLProtocolMock.formParameters)?["fileid"])
	}

	func testCreateFolderFindsCollidingFolder() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 1, name: "a.txt"), PCloudMockResponse.folderEntry(id: 2, name: "b"), PCloudMockResponse.fileEntry(id: 3, name: "c.txt")])),
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 4, name: "b"))
		]

		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: CloudPath("/b"))) { error in
			XCTAssertEqual(.itemAlreadyExists, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	// MARK: - Paging

	func testFetchItemListPagesThroughSnapshotWithoutRequests() async throws {
		let provider = try PCloudCloudProvider(client: .mocked(), maxPageSize: 2)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFiles(["a", "b", "c", "d", "e"]))]

		let firstPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		let secondPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: XCTUnwrap(firstPage.nextPageToken))
		let thirdPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: XCTUnwrap(secondPage.nextPageToken))

		XCTAssertEqual(["a", "b"], firstPage.items.map(\.name))
		XCTAssertEqual(["c", "d"], secondPage.items.map(\.name))
		XCTAssertEqual(["e"], thirdPage.items.map(\.name))
		XCTAssertNil(thirdPage.nextPageToken)
		PCloudProviderTestResponse.assertMetadata(thirdPage.items[0], name: "e", cloudPath: CloudPath("/e"), itemType: .file, size: 7)
	}

	/// An item whose name is no single path component gets no snapshot position, because a gap in the positions would drop a later item from the pages. It gets no cached identifier either, so that it shadows no path and doesn't replace the cached root.
	func testListingSkipsNamesThatAreNoSinglePathComponent() async throws {
		let provider = try PCloudCloudProvider(client: .mocked(), maxPageSize: 2)
		let requests = RequestRecorder()
		let root = PCloudProviderTestResponse.rootWithFiles(["a", "b", ".", "x/y", "c"])
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: root), URLProtocolMock.handler(body: root, onRequest: requests.record)]

		let firstPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		let secondPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: XCTUnwrap(firstPage.nextPageToken))
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/x/y"))) { error in
			XCTAssertEqual(.itemNotFound, error as? CloudProviderError)
		}

		XCTAssertEqual(["a", "b"], firstPage.items.map(\.name))
		XCTAssertEqual(["c"], secondPage.items.map(\.name))
		XCTAssertNil(secondPage.nextPageToken)
		XCTAssertEqual(["0"], requests.requests.map { URLProtocolMock.formParameters(of: $0)["folderid"] })
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testInterleavedListingsOfSameFolderSeeTheirOwnItems() async throws {
		let provider = try PCloudCloudProvider(client: .mocked(), maxPageSize: 2)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFiles(["a", "b", "c"])),
			URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFiles(["x", "y", "z"]))
		]

		let firstListing = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		let secondListing = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		let firstListingRest = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: XCTUnwrap(firstListing.nextPageToken))
		let secondListingRest = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: XCTUnwrap(secondListing.nextPageToken))

		XCTAssertEqual(["a", "b", "c"], (firstListing.items + firstListingRest.items).map(\.name))
		XCTAssertEqual(["x", "y", "z"], (secondListing.items + secondListingRest.items).map(\.name))
	}

	func testUnpublishedPageTokensThrowPageTokenInvalid() async throws {
		let provider = try PCloudCloudProvider(client: .mocked(), maxPageSize: 1)
		let listings = DirectoryContentDBCache.retainedSnapshotsPerFolder + 1
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 3, name: "folder"), PCloudMockResponse.fileEntry(id: 5, name: "file.txt")])), count: listings)
		var pageTokens = [String]()
		for _ in 0 ..< listings {
			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			try pageTokens.append(XCTUnwrap(itemList.nextPageToken))
		}

		let cases = [(CloudPath("/folder"), pageTokens[listings - 1]), (CloudPath("/"), "invalid"), (CloudPath("/"), pageTokens[0])]
		for (cloudPath, pageToken) in cases {
			await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: pageToken), pageToken) { error in
				XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError, pageToken)
			}
		}
		_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: pageTokens[1])
	}

	func testListingsLeaveNoFilesAndReleaseRemovesTemporaryDirectory() async throws {
		var provider: PCloudCloudProvider? = try PCloudCloudProvider(client: .mocked())
		let tmpDirURL = try XCTUnwrap(provider?.tmpDirURL)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFiles(["a"])), URLProtocolMock.handler(body: PCloudMockResponse.result(2005))]

		_ = try await provider?.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		await XCTAssertThrowsErrorAsync(try await provider?.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)) { error in
			XCTAssertEqual(.itemNotFound, error as? CloudProviderError)
		}
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: tmpDirURL.path).filter { !$0.hasPrefix("db.sqlite") })

		provider = nil
		XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDirURL.path))
	}

	func testFailedFillLeavesNoRows() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "a.txt"), #"{"isfolder":false,"name":"b.txt","modified":1792056600,"size":7}"#]))]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)) { error in
			XCTAssertEqual(.unexpectedContent, error as? PCloudError)
		}

		try assertDirectoryContentCacheIsEmpty(provider.directoryContentCache)
	}

	func testCancelledFillStopsAtNextChild() async throws {
		let cache = try SaveCountingDirectoryContentCache(cache: DirectoryContentDBCache(dbWriter: DatabaseQueue(), maxPageSize: .max))
		let provider = try PCloudCloudProvider(client: .mocked(), directoryContentCache: cache)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFiles(["a", "b", "c"]))]

		let listing = Task {
			try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		}
		await XCTAssertThrowsErrorAsync(try await value(of: listing)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}

		XCTAssertEqual(1, cache.saveCount)
		try assertDirectoryContentCacheIsEmpty(cache.cache)
	}

	func testFetchItemListOfFileThrowsItemTypeMismatchWithoutListing() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFile),
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 5))
		]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/file.txt"), withPageToken: nil)) { error in
			XCTAssertEqual(.itemTypeMismatch, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	// MARK: - Logging

	func testDownloadFileLeavesNoFileLinkInLog() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(body: "content")]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: nil, onTaskCreation: nil)

		let log = logCapture.joinedMessages
		for secret in [PCloudCredential.stubAccessToken, PCloudMockResponse.link.path, PCloudMockResponse.link.dwltag] {
			XCTAssertFalse(log.contains(secret), "\(secret) in \(log)")
		}
	}

	// MARK: - Transfers

	func testDownloadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: PCloudCloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(body: "content", onRequest: { _ in
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

	func testUploadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: PCloudCloudProvider = provider
		let localURL = try makeLocalFile()
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0)),
			URLProtocolMock.handler(body: PCloudMockResponse.uploadedFile(id: 5), onRequest: { _ in
				XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
			})
		]

		let metadata = try await value(of: Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		})

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(CloudPath("/file.txt"), metadata.cloudPath)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadFileWithCancellationDuringOnTaskCreation() async throws {
		let provider: PCloudCloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(body: "content")]

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

	func testUploadFileWithCancellationDuringOnTaskCreation() async throws {
		let provider: PCloudCloudProvider = provider
		let localURL = try makeLocalFile()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0)),
			URLProtocolMock.handler(body: PCloudMockResponse.uploadedFile(id: 5))
		]

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

	func testDownloadFileReportsBytesOfTask() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try PCloudCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions, excluding: PCloudProviderTestResponse.isListing)))
		URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: progress, onTaskCreation: nil)

		assertTransferProgress(fractions.withLock { $0 })
		XCTAssertEqual(1, progress.fractionCompleted)
	}

	func testUploadFileReportsBytesOfTask() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try PCloudCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions, excluding: PCloudProviderTestResponse.isListing)))
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0)),
			URLProtocolMock.handler(body: PCloudMockResponse.uploadedFile(id: 5))
		]

		_ = try await provider.uploadFile(from: makeLocalFile(), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

		assertTransferProgress(fractions.withLock { $0 })
		XCTAssertEqual(1, progress.fractionCompleted)
	}

	// MARK: - Helpers

	private func assertTransferProgress(_ fractions: [Double], file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertEqual(1, fractions.count, "Unexpected number of transfer tasks", file: file, line: line)
		XCTAssertGreaterThan(fractions.first ?? 0, 0.5, "The progress of the transfer task isn't part of the transfer's progress", file: file, line: line)
		XCTAssertLessThan(fractions.first ?? 1, 1, "The progress completed before the transfer returned", file: file, line: line)
	}

	private func makeLocalFile() throws -> URL {
		let localURL = tmpDirURL.appendingPathComponent("local.txt")
		try Data("content".utf8).write(to: localURL)
		return localURL
	}
}

private struct ProviderCase<Expected: Error & Equatable>: Sendable {
	let name: String
	let responses: [String]
	let operation: @Sendable (PCloudCloudProvider) async throws -> Void
	let expected: Expected
}

private enum PCloudProviderTestResponse {
	static let rootWithFile = PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "file.txt")])

	static let isListing: @Sendable (URLSessionTask) -> Bool = { $0.originalRequest?.url?.path == "/listfolder" }
	static let folderWithNullContents = #"{"result":0,"metadata":{"isfolder":true,"name":"folder","folderid":3,"modified":1792056600,"contents":null}}"#

	/// The root folder with a file of each name, whose identifiers count from 1.
	static func rootWithFiles(_ names: [String]) -> String {
		return PCloudMockResponse.folder(id: 0, contents: names.enumerated().map { PCloudMockResponse.fileEntry(id: UInt64($0 + 1), name: $1) })
	}

	/// The listing, `stat` and `getfilelink` that precede the download of `/file.txt`.
	static var downloadPreparation: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
		return [
			URLProtocolMock.handler(body: rootWithFile),
			URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5)),
			URLProtocolMock.handler(body: PCloudMockResponse.fileLink())
		]
	}

	static func assertMetadata(_ metadata: CloudItemMetadata, name: String, cloudPath: CloudPath, itemType: CloudItemType, size: Int?, file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertEqual(name, metadata.name, file: file, line: line)
		XCTAssertEqual(cloudPath, metadata.cloudPath, file: file, line: line)
		XCTAssertEqual(itemType, metadata.itemType, file: file, line: line)
		XCTAssertEqual(Date(timeIntervalSince1970: 1_792_056_600), metadata.lastModifiedDate, file: file, line: line)
		XCTAssertEqual(size, metadata.size, file: file, line: line)
	}
}

/// Forwards to a cache, and cancels the current task when the first element is saved.
private final class SaveCountingDirectoryContentCache: DirectoryContentCache {
	let cache: DirectoryContentDBCache
	private let saves = OSAllocatedUnfairLock(initialState: 0)

	var saveCount: Int {
		return saves.withLock { $0 }
	}

	init(cache: DirectoryContentDBCache) {
		self.cache = cache
	}

	func save(_ element: CloudItemMetadata, in snapshot: DirectoryContentSnapshot, index: Int64) throws {
		let count = saves.withLock {
			$0 += 1
			return $0
		}
		if count == 1 {
			withUnsafeCurrentTask { $0?.cancel() }
		}
		try cache.save(element, in: snapshot, index: index)
	}

	func discard(_ snapshot: DirectoryContentSnapshot) throws {
		try cache.discard(snapshot)
	}

	func publish(_ snapshot: DirectoryContentSnapshot) throws -> CloudItemList {
		return try cache.publish(snapshot)
	}

	func getPage(for folderPath: CloudPath, pageToken: String) throws -> CloudItemList {
		return try cache.getPage(for: folderPath, pageToken: pageToken)
	}
}
