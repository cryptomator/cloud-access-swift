//
//  LocalFileSystemTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class LocalFileSystemTests {
		let tmpDirURL: URL
		let provider: LocalFileSystemProvider
		private var lockedURLs: [URL] = []

		init() throws {
			let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			self.provider = try LocalFileSystemProvider(rootURL: tmpDirURL)
			self.tmpDirURL = tmpDirURL
		}

		deinit {
			for lockedURL in lockedURLs {
				do {
					try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedURL.path)
				} catch {
					Issue.record(error)
				}
			}
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func testFetchItemMetadata() async throws {
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/file"))
			#expect(metadata.name == "file")
			#expect(metadata.cloudPath.path == "/file")
			#expect(metadata.itemType == .file)
			#expect(metadata.lastModifiedDate != nil)
			#expect(metadata.size == 11)
		}

		@Test
		func fetchItemMetadataWithNotFoundError() async {
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/file")) }
		}

		@Test(arguments: ["/file/child", "/file/child/grandchild"])
		func fetchItemMetadataBelowFile(path: String) async throws {
			try makeFile()
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath(path)) }
			#expect(try await !provider.checkForItemExistence(at: CloudPath(path)))
		}

		@Test
		func testFetchItemList() async throws {
			let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
			try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect(itemList.items.count == 2)
			#expect(itemList.items.contains(where: { $0.name == "dir" && $0.cloudPath.path == "/dir" }))
			#expect(itemList.items.contains(where: { $0.name == "file" && $0.cloudPath.path == "/file" }))
			#expect(itemList.nextPageToken == nil)
			try assertDirectoryContentCacheIsEmpty(provider.cache)
		}

		@Test
		func fetchItemListInterleavedWithAnotherListingOfTheSameFolder() async throws {
			let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, maxPageSize: 2)
			let names = (0 ..< 5).map { "file \($0)" }
			for name in names {
				FileManager.default.createFile(atPath: tmpDirURL.appendingPathComponent(name, isDirectory: false).path, contents: nil, attributes: nil)
			}

			let firstPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			let deletedName = try #require(firstPage.items.first).name
			try FileManager.default.removeItem(at: tmpDirURL.appendingPathComponent(deletedName, isDirectory: false))
			let otherItemList = try await provider.fetchItemListExhaustively(forFolderAt: CloudPath("/"))
			let itemList = try await provider.fetchItemListExhaustively(forFolderAt: CloudPath("/"), appendTo: firstPage)

			#expect(names == itemList.items.map(\.name).sorted())
			#expect(names.filter { $0 != deletedName } == otherItemList.items.map(\.name).sorted())
		}

		@Test
		func fetchItemListWithNotFoundError() async {
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemList(forFolderAt: CloudPath("/dir"), withPageToken: nil) }
		}

		@Test
		func fetchItemListWithTypeMismatchError() async throws {
			let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
			FileManager.default.createFile(atPath: dirURL.path, contents: nil, attributes: nil)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.fetchItemList(forFolderAt: CloudPath("/dir"), withPageToken: nil) }
		}

		@Test(arguments: ["/file/child", "/file/child/grandchild"])
		func fetchItemListBelowFile(path: String) async throws {
			try makeFile()
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemList(forFolderAt: CloudPath(path), withPageToken: nil) }
		}

		@Test
		func fetchItemListFiltersHiddenItems() async throws {
			let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
			try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
			let hiddenDirURL = tmpDirURL.appendingPathComponent(".hiddenDir", isDirectory: true)
			try FileManager.default.createDirectory(at: hiddenDirURL, withIntermediateDirectories: false, attributes: nil)
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
			let hiddenFileURL = tmpDirURL.appendingPathComponent(".hiddenFile", isDirectory: false)
			FileManager.default.createFile(atPath: hiddenFileURL.path, contents: nil, attributes: nil)
			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect(itemList.items.count == 2)
			#expect(itemList.items.contains(where: { $0.name == "dir" && $0.cloudPath.path == "/dir" }))
			#expect(itemList.items.contains(where: { $0.name == "file" && $0.cloudPath.path == "/file" }))
		}

		@Test
		func testDownloadFile() async throws {
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let progress = Progress(totalUnitCount: 1)
			let metadata = try await provider.downloadFile(from: CloudPath("/file"), to: localURL, progress: progress, onTaskCreation: nil)
			let expectedData = try Data(contentsOf: fileURL)
			let actualData = try Data(contentsOf: localURL)
			#expect(expectedData == actualData)
			#expect(metadata.name == "file")
			#expect(metadata.cloudPath.path == "/file")
			#expect(metadata.itemType == .file)
			#expect(try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == metadata.lastModifiedDate)
			#expect(metadata.size == 11)
			#expect(progress.fractionCompleted == 1)
		}

		@Test
		func downloadFileWithNotFoundError() async {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.downloadFile(from: CloudPath("/file"), to: localURL) }
		}

		@Test(arguments: ["/file/child", "/file/child/grandchild"])
		func downloadFileWithNotFoundErrorBelowFile(path: String) async throws {
			try makeFile()
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.downloadFile(from: CloudPath(path), to: localURL) }
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func downloadFileWithAlreadyExistsError() async {
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.downloadFile(from: CloudPath("/file"), to: localURL) }
		}

		@Test
		func downloadFileWithTypeMismatchError() async throws {
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false, attributes: nil)
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.downloadFile(from: CloudPath("/file"), to: localURL) }
		}

		@Test
		func testUploadFile() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false)
			#expect(metadata.name == "file")
			#expect(metadata.cloudPath.path == "/file")
			#expect(metadata.itemType == .file)
			#expect(metadata.lastModifiedDate != nil)
			#expect(metadata.size == 11)
		}

		@Test
		func uploadFileWithReplaceExistingOnMissingRemoteFile() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: true)
			#expect(metadata.name == "file")
			#expect(metadata.cloudPath.path == "/file")
			#expect(metadata.itemType == .file)
			#expect(metadata.lastModifiedDate != nil)
			#expect(metadata.size == 11)
		}

		@Test
		func uploadFileWithReplaceExistingOnExistingRemoteFile() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			try "foo bar".write(to: fileURL, atomically: true, encoding: .utf8)
			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: true)
			#expect(metadata.name == "file")
			#expect(metadata.cloudPath.path == "/file")
			#expect(metadata.itemType == .file)
			#expect(metadata.lastModifiedDate != nil)
			#expect(metadata.size == 11)
		}

		@Test
		func uploadFileThroughSymbolicLinkCopiesTarget() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
			let linkURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: localURL)
			let metadata = try await provider.uploadFile(from: linkURL, to: CloudPath("/file"), replaceExisting: false)
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			#expect(try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
			#expect(try String(contentsOf: fileURL, encoding: .utf8) == "hello world")
			#expect(metadata.size == 11)
		}

		@Test
		func uploadFileWithNotFoundError() async {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false) }
		}

		@Test
		func uploadFileWithAlreadyExistsError() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false) }
		}

		@Test
		func uploadFileWithTypeMismatchError() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false, attributes: nil)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false) }
		}

		@Test
		func uploadFileWithReplaceExistingAndAlreadyExistsError() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
			let fileURL = tmpDirURL.appendingPathComponent("dir", isDirectory: false)
			try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false, attributes: nil)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.uploadFile(from: localURL, to: CloudPath("/dir"), replaceExisting: true) }
		}

		@Test
		func uploadFileWithParentFolderDoesNotExistError() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.uploadFile(from: localURL, to: CloudPath("/dir/file"), replaceExisting: false) }
		}

		@Test(arguments: ["/file/child", "/file/child/grandchild"], [false, true])
		func uploadFileBelowFile(path: String, replaceExisting: Bool) async throws {
			try makeFile()
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.uploadFile(from: localURL, to: CloudPath(path), replaceExisting: replaceExisting) }
		}

		@Test
		func testCreateFolder() async throws {
			let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
			try await provider.createFolder(at: CloudPath("/dir"))
			var isDirectory: ObjCBool = false
			#expect(FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDirectory))
			#expect(isDirectory.boolValue)
		}

		@Test
		func createFolderWithAlreadyExistsError() async throws {
			let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
			try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.createFolder(at: CloudPath("/dir")) }
		}

		@Test
		func createFolderWithParentFolderDoesNotExistError() async {
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.createFolder(at: CloudPath("/dir/dir")) }
		}

		@Test(arguments: ["/file/child", "/file/child/grandchild"])
		func createFolderBelowFile(path: String) async throws {
			try makeFile()
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.createFolder(at: CloudPath(path)) }
		}

		@Test
		func testDeleteFile() async throws {
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
			try await provider.deleteFile(at: CloudPath("/file"))
			#expect(!FileManager.default.fileExists(atPath: fileURL.path))
		}

		@Test
		func deleteFileWithNotFoundError() async {
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.deleteFile(at: CloudPath("/file")) }
		}

		@Test(arguments: ["/file/child", "/file/child/grandchild"])
		func deleteFileBelowFile(path: String) async throws {
			try makeFile()
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.deleteFile(at: CloudPath(path)) }
		}

		@Test
		func testDeleteFolder() async throws {
			let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
			try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
			let fileURL = tmpDirURL.appendingPathComponent("dir/file", isDirectory: false)
			FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
			try await provider.deleteFolder(at: CloudPath("/dir"))
			#expect(!FileManager.default.fileExists(atPath: dirURL.path))
		}

		@Test
		func testMoveFile() async throws {
			let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
			FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
			let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: false)
			try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar"))
			#expect(!FileManager.default.fileExists(atPath: sourceURL.path))
			#expect(FileManager.default.fileExists(atPath: destinationURL.path))
		}

		@Test
		func moveFileWithNotFoundError() async {
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar")) }
		}

		@Test
		func moveFileWithAlreadyExistsError() async {
			let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
			FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
			let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: false)
			FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar")) }
		}

		@Test
		func moveFileWithParentFolderDoesNotExistError() async {
			let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
			FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar/baz")) }
		}

		@Test(arguments: ["/file/child", "/file/child/grandchild"])
		func moveFileWithSourceBelowFile(path: String) async throws {
			try makeFile()
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.moveFile(from: CloudPath(path), to: CloudPath("/bar")) }
			FileManager.default.createFile(atPath: tmpDirURL.appendingPathComponent("bar", isDirectory: false).path, contents: nil, attributes: nil)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.moveFile(from: CloudPath(path), to: CloudPath("/bar")) }
		}

		@Test(arguments: ["/file/child", "/file/child/grandchild"])
		func moveFileWithTargetBelowFile(path: String) async throws {
			try makeFile()
			let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
			FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath(path)) }
			#expect(FileManager.default.fileExists(atPath: sourceURL.path))
		}

		@Test(arguments: ["/file/child", "/file/child/grandchild"])
		func moveFileWithMissingSourceAndTargetBelowFile(path: String) async throws {
			try makeFile()
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath(path)) }
		}

		/// A local folder that the system refuses to read can't be fixed by signing in, so the system's error passes through.
		@Test
		func fetchItemMetadataWithReadPermissionError() async throws {
			try makeLockedFolder()
			let error = try await #require(throws: (any Error).self) { try await provider.fetchItemMetadata(at: CloudPath("/locked/file")) }
			#expect((error as? CocoaError)?.code == .fileReadNoPermission, "\(error)")
		}

		/// See the rationale on the metadata variant.
		@Test
		func fetchItemListWithReadPermissionError() async throws {
			try makeLockedFolder()
			let error = try await #require(throws: (any Error).self) { try await provider.fetchItemList(forFolderAt: CloudPath("/locked/dir"), withPageToken: nil) }
			#expect((error as? CocoaError)?.code == .fileReadNoPermission, "\(error)")
		}

		/// See the rationale on the metadata variant.
		@Test
		func downloadFileWithReadPermissionError() async throws {
			try makeLockedFolder()
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let error = try await #require(throws: (any Error).self) { try await provider.downloadFile(from: CloudPath("/locked/file"), to: localURL) }
			#expect((error as? CocoaError)?.code == .fileReadNoPermission, "\(error)")
		}

		/// See the rationale on the metadata variant.
		@Test
		func uploadFileWithReadPermissionError() async throws {
			try makeLockedFolder()
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
			let error = try await #require(throws: (any Error).self) { try await provider.uploadFile(from: localURL, to: CloudPath("/locked/file"), replaceExisting: true) }
			#expect((error as? CocoaError)?.code == .fileReadNoPermission, "\(error)")
		}

		@Test
		func securityScopedAccessIsStoppedAfterEachOperation() async throws {
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
			#expect([.start(tmpDirURL.path)] == recorder.takeEvents())
			let fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

			recorder.isOperationFinished = { fileExists(filePath) }
			_ = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false)
			#expect([.start(filePath), .stop(filePath, isOperationFinished: true)] == recorder.takeEvents())

			recorder.isOperationFinished = { true }
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file"))
			#expect([.start(filePath), .stop(filePath, isOperationFinished: true)] == recorder.takeEvents())

			recorder.isOperationFinished = { fileExists(downloadURL.path) }
			_ = try await provider.downloadFile(from: CloudPath("/file"), to: downloadURL)
			#expect([.start(filePath), .stop(filePath, isOperationFinished: true)] == recorder.takeEvents())

			recorder.isOperationFinished = { fileExists(movedFilePath) && !fileExists(filePath) }
			try await provider.moveFile(from: CloudPath("/file"), to: CloudPath("/movedFile"))
			#expect([.start(filePath), .stop(filePath, isOperationFinished: true)] == recorder.takeEvents())

			recorder.isOperationFinished = { !fileExists(movedFilePath) }
			try await provider.deleteFile(at: CloudPath("/movedFile"))
			#expect([.start(movedFilePath), .stop(movedFilePath, isOperationFinished: true)] == recorder.takeEvents())

			recorder.isOperationFinished = { fileExists(dirPath) }
			try await provider.createFolder(at: CloudPath("/dir"))
			#expect([.start(dirPath), .stop(dirPath, isOperationFinished: true)] == recorder.takeEvents())

			recorder.isOperationFinished = { true }
			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/dir"), withPageToken: nil)
			#expect([.start(dirPath), .stop(dirPath, isOperationFinished: true)] == recorder.takeEvents())

			recorder.isOperationFinished = { fileExists(movedDirPath) && !fileExists(dirPath) }
			try await provider.moveFolder(from: CloudPath("/dir"), to: CloudPath("/movedDir"))
			#expect([.start(dirPath), .stop(dirPath, isOperationFinished: true)] == recorder.takeEvents())

			recorder.isOperationFinished = { !fileExists(movedDirPath) }
			try await provider.deleteFolder(at: CloudPath("/movedDir"))
			#expect([.start(movedDirPath), .stop(movedDirPath, isOperationFinished: true)] == recorder.takeEvents())
		}

		@Test
		func securityScopedAccessIsStoppedAfterUploadCompletedItsProgress() async throws {
			let filePath = tmpDirURL.appendingPathComponent("file").path
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
			let recorder = SecurityScopedAccessRecorder()
			let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
			_ = recorder.takeEvents()
			let progress = Progress(totalUnitCount: 1)
			recorder.isOperationFinished = { progress.fractionCompleted == 1 }
			_ = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false, progress: progress, onTaskCreation: nil)
			#expect([.start(filePath), .stop(filePath, isOperationFinished: true)] == recorder.takeEvents())
		}

		@Test
		func securityScopedAccessIsStoppedAfterDownloadCompletedItsProgress() async throws {
			try makeFile()
			let filePath = tmpDirURL.appendingPathComponent("file").path
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let recorder = SecurityScopedAccessRecorder()
			let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
			_ = recorder.takeEvents()
			let progress = Progress(totalUnitCount: 1)
			recorder.isOperationFinished = { progress.fractionCompleted == 1 }
			_ = try await provider.downloadFile(from: CloudPath("/file"), to: localURL, progress: progress, onTaskCreation: nil)
			#expect([.start(filePath), .stop(filePath, isOperationFinished: true)] == recorder.takeEvents())
		}

		@Test
		func securityScopedAccessIsStoppedAfterListingFilledItsSnapshot() async throws {
			let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
			try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
			for name in ["file 0", "file 1"] {
				FileManager.default.createFile(atPath: dirURL.appendingPathComponent(name, isDirectory: false).path, contents: nil, attributes: nil)
			}
			let recorder = SecurityScopedAccessRecorder()
			let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
			_ = recorder.takeEvents()
			let cache = try #require(provider.cache as? DirectoryContentDBCache)
			// A snapshot that fits on its first page is deleted when it's published, so its rows exist only until then.
			recorder.isOperationFinished = { (try? rowCount(of: "entries", in: cache)) == 2 }
			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/dir"), withPageToken: nil)
			#expect([.start(dirURL.path), .stop(dirURL.path, isOperationFinished: true)] == recorder.takeEvents())
		}

		@Test
		func securityScopedAccessIsStoppedAfterFailedOperation() async throws {
			let filePath = tmpDirURL.appendingPathComponent("file").path
			let recorder = SecurityScopedAccessRecorder()
			let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
			_ = recorder.takeEvents()
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/file")) }
			#expect([.start(filePath), .stop(filePath, isOperationFinished: true)] == recorder.takeEvents())
		}

		@Test
		func throwsCancellationErrorInCancelledTask() async throws {
			let recorder = SecurityScopedAccessRecorder()
			let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
			_ = recorder.takeEvents()
			await assertThrowsCancellationErrorInCancelledTask(provider)
			#expect(recorder.takeEvents() == [])
		}

		@Test
		func downloadFileWithCancellationDuringDownload() async throws {
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let recorder = SecurityScopedAccessRecorder()
			let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
			recorder.cancelsTaskOnStart = true
			let download = Task {
				try await provider.downloadFile(from: CloudPath("/file"), to: localURL)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func uploadFileWithCancellationDuringUpload() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
			let recorder = SecurityScopedAccessRecorder()
			let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
			recorder.cancelsTaskOnStart = true
			let upload = Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false)
			}
			let metadata = try await cancellingValue(of: upload)
			#expect(metadata.name == "file")
			#expect(metadata.size == 11)
		}

		@Test
		func fetchItemListWithCancellationDuringListing() async throws {
			let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
			FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
			let recorder = SecurityScopedAccessRecorder()
			let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
			recorder.cancelsTaskOnStart = true
			let listing = Task {
				try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: listing) }
			recorder.cancelsTaskOnStart = false
			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect(itemList.items.map(\.name) == ["file"])
		}

		@Test
		func fetchItemListWithCancellationAfterFillLeavesNoRows() async throws {
			let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
			try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
			for name in ["file 0", "file 1", "file 2"] {
				FileManager.default.createFile(atPath: dirURL.appendingPathComponent(name, isDirectory: false).path, contents: nil, attributes: nil)
			}
			let recorder = SecurityScopedAccessRecorder()
			let provider = try LocalFileSystemProvider(rootURL: tmpDirURL, securityScopedAccess: recorder.securityScopedAccess)
			// Stopping the access to the folder is the last step of the fill, after every child was saved.
			recorder.isOperationFinished = {
				withUnsafeCurrentTask { $0?.cancel() }
				return true
			}
			let listing = Task {
				try await provider.fetchItemList(forFolderAt: CloudPath("/dir"), withPageToken: nil)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: listing) }
			recorder.isOperationFinished = { true }

			try assertDirectoryContentCacheIsEmpty(provider.cache)
		}

		@Test
		func convertNotDirectoryErrors() {
			let notDirectory = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
			let ioError = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
			#expect((provider.convertStandardError(CocoaError(.fileReadUnknown, userInfo: [NSUnderlyingErrorKey: notDirectory])) as? CloudProviderError) == .itemNotFound)
			#expect((provider.convertStandardError(CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: notDirectory])) as? CloudProviderError) == .itemNotFound)
			let unchangedErrors = [
				CocoaError(.fileReadUnknown, userInfo: [NSUnderlyingErrorKey: ioError]),
				CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: ioError]),
				CocoaError(.fileReadUnknown),
				CocoaError(.fileReadNoPermission),
				CocoaError(.fileWriteOutOfSpace)
			]
			for error in unchangedErrors {
				#expect((provider.convertStandardError(error) as? CocoaError) == error, "\(error)")
			}
			#expect((provider.convertCreationError(CocoaError(.fileWriteOutOfSpace)) as? CloudProviderError) == .quotaInsufficient)
			#expect((provider.convertCreationError(CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: notDirectory])) as? CloudProviderError) == .parentFolderDoesNotExist)
			let ioWriteError = CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: ioError])
			#expect((provider.convertCreationError(ioWriteError) as? CocoaError) == ioWriteError)
		}

		@Test
		func testGetItemName() {
			let iCloudPlaceholderFileURL = tmpDirURL.appendingPathComponent(".test.txt.icloud")
			#expect(provider.getItemName(forItemAt: iCloudPlaceholderFileURL) == "test.txt")

			let normalFileURL = tmpDirURL.appendingPathComponent("test.txt")
			#expect(provider.getItemName(forItemAt: normalFileURL) == "test.txt")

			let normalFolderURL = tmpDirURL.appendingPathComponent("Foo")
			#expect(provider.getItemName(forItemAt: normalFolderURL) == "Foo")

			let otherHiddenFileURL = tmpDirURL.appendingPathComponent(".test.txt")
			#expect(provider.getItemName(forItemAt: otherHiddenFileURL) == ".test.txt")

			let otherHiddenFolderURL = tmpDirURL.appendingPathComponent(".Foo")
			#expect(provider.getItemName(forItemAt: otherHiddenFolderURL) == ".Foo")
		}

		/// Creates the regular file `/file`.
		private func makeFile() throws {
			try "hello world".write(to: tmpDirURL.appendingPathComponent("file", isDirectory: false), atomically: true, encoding: .utf8)
		}

		/// Creates the file `/locked/file` and the folder `/locked/dir`, and takes every permission from `/locked` until the test ends.
		private func makeLockedFolder() throws {
			let lockedURL = tmpDirURL.appendingPathComponent("locked", isDirectory: true)
			try FileManager.default.createDirectory(at: lockedURL.appendingPathComponent("dir", isDirectory: true), withIntermediateDirectories: true)
			try "hello world".write(to: lockedURL.appendingPathComponent("file", isDirectory: false), atomically: true, encoding: .utf8)
			try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedURL.path)
			lockedURLs.append(lockedURL)
		}
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
