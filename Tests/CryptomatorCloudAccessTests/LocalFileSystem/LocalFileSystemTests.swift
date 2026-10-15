//
//  LocalFileSystemTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class LocalFileSystemTests: XCTestCase {
	var tmpDirURL: URL!
	var provider: LocalFileSystemProvider!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		provider = try LocalFileSystemProvider(rootURL: tmpDirURL)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/file"))
		XCTAssertEqual("file", metadata.name)
		XCTAssertEqual("/file", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertNotNil(metadata.lastModifiedDate)
		XCTAssertEqual(11, metadata.size)
	}

	func testFetchItemMetadataWithNotFoundError() async {
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/file"))) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testFetchItemList() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		XCTAssertEqual(2, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "dir" && $0.cloudPath.path == "/dir" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "file" && $0.cloudPath.path == "/file" }))
	}

	func testFetchItemListWithNotFoundError() async {
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/dir"), withPageToken: nil)) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testFetchItemListWithTypeMismatchError() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		FileManager.default.createFile(atPath: dirURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/dir"), withPageToken: nil)) { error in
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testFetchItemListFiltersHiddenItems() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		let hiddenDirURL = tmpDirURL.appendingPathComponent(".hiddenDir", isDirectory: true)
		try FileManager.default.createDirectory(at: hiddenDirURL, withIntermediateDirectories: false, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		let hiddenFileURL = tmpDirURL.appendingPathComponent(".hiddenFile", isDirectory: false)
		FileManager.default.createFile(atPath: hiddenFileURL.path, contents: nil, attributes: nil)
		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		XCTAssertEqual(2, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "dir" && $0.cloudPath.path == "/dir" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "file" && $0.cloudPath.path == "/file" }))
	}

	func testDownloadFile() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)
		let metadata = try await provider.downloadFile(from: CloudPath("/file"), to: localURL, progress: progress, onTaskCreation: nil)
		let expectedData = try Data(contentsOf: fileURL)
		let actualData = try Data(contentsOf: localURL)
		XCTAssertEqual(expectedData, actualData)
		XCTAssertEqual("file", metadata.name)
		XCTAssertEqual("/file", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, metadata.lastModifiedDate)
		XCTAssertEqual(11, metadata.size)
		XCTAssertEqual(1, progress.fractionCompleted)
	}

	func testDownloadFileWithNotFoundError() async {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file"), to: localURL)) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithNotFoundErrorBelowFile() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file/child"), to: localURL)) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithAlreadyExistsError() async {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file"), to: localURL)) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithTypeMismatchError() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false, attributes: nil)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file"), to: localURL)) { error in
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testUploadFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false)
		XCTAssertEqual("file", metadata.name)
		XCTAssertEqual("/file", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertNotNil(metadata.lastModifiedDate)
		XCTAssertEqual(11, metadata.size)
	}

	func testUploadFileWithReplaceExistingOnMissingRemoteFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: true)
		XCTAssertEqual("file", metadata.name)
		XCTAssertEqual("/file", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertNotNil(metadata.lastModifiedDate)
		XCTAssertEqual(11, metadata.size)
	}

	func testUploadFileWithReplaceExistingOnExistingRemoteFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "foo bar".write(to: fileURL, atomically: true, encoding: .utf8)
		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: true)
		XCTAssertEqual("file", metadata.name)
		XCTAssertEqual("/file", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertNotNil(metadata.lastModifiedDate)
		XCTAssertEqual(11, metadata.size)
	}

	func testUploadFileWithNotFoundError() async {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false)) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testUploadFileWithAlreadyExistsError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false)) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testUploadFileWithTypeMismatchError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false)) { error in
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testUploadFileWithReplaceExistingAndAlreadyExistsError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("dir", isDirectory: false)
		try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/dir"), replaceExisting: true)) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testUploadFileWithParentFolderDoesNotExistError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/dir/file"), replaceExisting: false)) { error in
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testCreateFolder() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try await provider.createFolder(at: CloudPath("/dir"))
		var isDirectory: ObjCBool = false
		XCTAssertTrue(FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDirectory))
		XCTAssertTrue(isDirectory.boolValue)
	}

	func testCreateFolderWithAlreadyExistsError() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: CloudPath("/dir"))) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testCreateFolderWithParentFolderDoesNotExistError() async {
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: CloudPath("/dir/dir"))) { error in
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testDeleteFile() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		try await provider.deleteFile(at: CloudPath("/file"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
	}

	func testDeleteFileWithNotFoundError() async {
		await XCTAssertThrowsErrorAsync(try await provider.deleteFile(at: CloudPath("/file"))) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDeleteFolder() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("dir/file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		try await provider.deleteFolder(at: CloudPath("/dir"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: dirURL.path))
	}

	func testMoveFile() async throws {
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: false)
		try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar"))
		XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
	}

	func testMoveFileWithNotFoundError() async {
		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar"))) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testMoveFileWithAlreadyExistsError() async {
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: false)
		FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar"))) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testMoveFileWithParentFolderDoesNotExistError() async {
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar/baz"))) { error in
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testSecurityScopedAccessIsStoppedAfterEachOperation() async throws {
		let tmpDirURL: URL = tmpDirURL
		let filePath = tmpDirURL.appendingPathComponent("file").path
		let movedFilePath = tmpDirURL.appendingPathComponent("movedFile").path
		let dirPath = tmpDirURL.appendingPathComponent("dir").path
		let movedDirPath = tmpDirURL.appendingPathComponent("movedDir").path
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
		let downloadURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let recorder = SecurityScopedAccessRecorder()
		let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
		XCTAssertEqual([.start(tmpDirURL.path)], recorder.takeEvents())
		let fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

		recorder.isOperationFinished = { fileExists(filePath) }
		_ = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false)
		XCTAssertEqual([.start(filePath), .stop(filePath, isOperationFinished: true)], recorder.takeEvents())

		recorder.isOperationFinished = { true }
		_ = try await provider.fetchItemMetadata(at: CloudPath("/file"))
		XCTAssertEqual([.start(filePath), .stop(filePath, isOperationFinished: true)], recorder.takeEvents())

		recorder.isOperationFinished = { fileExists(downloadURL.path) }
		_ = try await provider.downloadFile(from: CloudPath("/file"), to: downloadURL)
		XCTAssertEqual([.start(filePath), .stop(filePath, isOperationFinished: true)], recorder.takeEvents())

		recorder.isOperationFinished = { fileExists(movedFilePath) && !fileExists(filePath) }
		try await provider.moveFile(from: CloudPath("/file"), to: CloudPath("/movedFile"))
		XCTAssertEqual([.start(filePath), .stop(filePath, isOperationFinished: true)], recorder.takeEvents())

		recorder.isOperationFinished = { !fileExists(movedFilePath) }
		try await provider.deleteFile(at: CloudPath("/movedFile"))
		XCTAssertEqual([.start(movedFilePath), .stop(movedFilePath, isOperationFinished: true)], recorder.takeEvents())

		recorder.isOperationFinished = { fileExists(dirPath) }
		try await provider.createFolder(at: CloudPath("/dir"))
		XCTAssertEqual([.start(dirPath), .stop(dirPath, isOperationFinished: true)], recorder.takeEvents())

		recorder.isOperationFinished = { true }
		_ = try await provider.fetchItemList(forFolderAt: CloudPath("/dir"), withPageToken: nil)
		XCTAssertEqual([.start(dirPath), .stop(dirPath, isOperationFinished: true)], recorder.takeEvents())

		recorder.isOperationFinished = { fileExists(movedDirPath) && !fileExists(dirPath) }
		try await provider.moveFolder(from: CloudPath("/dir"), to: CloudPath("/movedDir"))
		XCTAssertEqual([.start(dirPath), .stop(dirPath, isOperationFinished: true)], recorder.takeEvents())

		recorder.isOperationFinished = { !fileExists(movedDirPath) }
		try await provider.deleteFolder(at: CloudPath("/movedDir"))
		XCTAssertEqual([.start(movedDirPath), .stop(movedDirPath, isOperationFinished: true)], recorder.takeEvents())
	}

	func testThrowsCancellationErrorInCancelledTask() async throws {
		let recorder = SecurityScopedAccessRecorder()
		let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
		_ = recorder.takeEvents()
		await assertThrowsCancellationErrorInCancelledTask(provider)
		XCTAssertEqual([], recorder.takeEvents())
	}

	func testDownloadFileWithCancellationDuringDownload() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let recorder = SecurityScopedAccessRecorder()
		let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
		recorder.cancelsTaskOnStart = true
		let download = Task {
			try await provider.downloadFile(from: CloudPath("/file"), to: localURL)
		}
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testUploadFileWithCancellationDuringUpload() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
		let recorder = SecurityScopedAccessRecorder()
		let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
		recorder.cancelsTaskOnStart = true
		let upload = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false)
		}
		let metadata = try await value(of: upload)
		XCTAssertEqual("file", metadata.name)
		XCTAssertEqual(11, metadata.size)
	}

	func testFetchItemListWithCancellationDuringListing() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		let recorder = SecurityScopedAccessRecorder()
		let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
		recorder.cancelsTaskOnStart = true
		let listing = Task {
			try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		}
		await XCTAssertThrowsErrorAsync(try await value(of: listing)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		recorder.cancelsTaskOnStart = false
		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		XCTAssertEqual(["file"], itemList.items.map(\.name))
	}

	func testGetItemName() {
		let iCloudPlaceholderFileURL = tmpDirURL.appendingPathComponent(".test.txt.icloud")
		XCTAssertEqual("test.txt", provider.getItemName(forItemAt: iCloudPlaceholderFileURL))

		let normalFileURL = tmpDirURL.appendingPathComponent("test.txt")
		XCTAssertEqual("test.txt", provider.getItemName(forItemAt: normalFileURL))

		let normalFolderURL = tmpDirURL.appendingPathComponent("Foo")
		XCTAssertEqual("Foo", provider.getItemName(forItemAt: normalFolderURL))

		let otherHiddenFileURL = tmpDirURL.appendingPathComponent(".test.txt")
		XCTAssertEqual(".test.txt", provider.getItemName(forItemAt: otherHiddenFileURL))

		let otherHiddenFolderURL = tmpDirURL.appendingPathComponent(".Foo")
		XCTAssertEqual(".Foo", provider.getItemName(forItemAt: otherHiddenFolderURL))
	}
}

/// Records the calls that a `LocalFileSystemProvider` makes to start and stop accessing security-scoped resources.
private final class SecurityScopedAccessRecorder: Sendable {
	enum Event: Equatable {
		case start(String)
		case stop(String, isOperationFinished: Bool)
	}

	private struct State {
		var events: [Event] = []
		var isOperationFinished: @Sendable () -> Bool = { true }
		var cancelsTaskOnStart = false
	}

	private let state = OSAllocatedUnfairLock(initialState: State())

	/// Evaluated when the access is stopped, to tell whether the effect of the running operation is already visible.
	var isOperationFinished: @Sendable () -> Bool {
		get { state.withLock { $0.isOperationFinished } }
		set { state.withLock { $0.isOperationFinished = newValue } }
	}

	/// Cancels the task of an operation after it passed its initial cancellation check.
	var cancelsTaskOnStart: Bool {
		get { state.withLock { $0.cancelsTaskOnStart } }
		set { state.withLock { $0.cancelsTaskOnStart = newValue } }
	}

	var securityScopedAccess: (start: @Sendable (URL) -> Bool, stop: @Sendable (URL) -> Void) {
		return (start: { url in
			self.state.withLock { $0.events.append(.start(url.path)) }
			if self.cancelsTaskOnStart {
				withUnsafeCurrentTask { $0?.cancel() }
			}
			return true
		}, stop: { url in
			let isOperationFinished = self.isOperationFinished()
			self.state.withLock { $0.events.append(.stop(url.path, isOperationFinished: isOperationFinished)) }
		})
	}

	func takeEvents() -> [Event] {
		return state.withLock { state in
			defer { state.events = [] }
			return state.events
		}
	}
}
