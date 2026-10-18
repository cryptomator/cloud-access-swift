//
//  VaultFormat6ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultFormat6ProviderDecoratorTests: XCTestCase {
	let vaultPath = CloudPath("pathToVault")
	let cryptor = VaultFormat6CryptorMock()
	var tmpDirURL: URL!
	var provider: VaultFormat6CloudProviderMock!
	var decorator: VaultFormat6ProviderDecorator!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		provider = VaultFormat6CloudProviderMock()
		decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
	}

	override func tearDownWithError() throws {
		decorator = nil
		provider = nil
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() async throws {
		let metadata = try await decorator.fetchItemMetadata(at: CloudPath("/Directory 1/File 3"))
		XCTAssertEqual("File 3", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/Directory 1/File 3", metadata.cloudPath.path)
	}

	func testFetchItemListForRootDir() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		XCTAssertEqual(3, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 1" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 2" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 1" }))
	}

	func testFetchItemListForSubDir() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1"), withPageToken: nil)
		XCTAssertEqual(2, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 3" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 2" }))
	}

	func testFetchItemListForEmptyDir() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1/Directory 2"), withPageToken: nil)
		XCTAssertTrue(itemList.items.isEmpty)
	}

	func testDownloadFile() async throws {
		let decorator: VaultFormat6ProviderDecorator = decorator
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)
		let transfer = SuspendedTransfer()
		provider.transferHook = transfer.run
		let download = Task {
			try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL, progress: progress, onTaskCreation: nil)
		}
		await fulfillment(of: [transfer.suspended], timeout: testWaitTimeout)
		XCTAssertGreaterThan(progress.fractionCompleted, 0)
		XCTAssertLessThan(progress.fractionCompleted, 1)
		transfer.resume()
		let metadata = try await value(of: download)
		XCTAssertEqual(1, progress.fractionCompleted)
		let cleartext = try String(contentsOf: localURL, encoding: .utf8)
		XCTAssertEqual("cleartext1", cleartext)
		XCTAssertEqual("File 1", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 1", metadata.cloudPath.path)
		XCTAssertEqual(provider.lastModifiedDate, metadata.lastModifiedDate)
		XCTAssertEqual(10, metadata.size)
		XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path))
	}

	func testDownloadFileWithFailingTransfer() async throws {
		let decorator: VaultFormat6ProviderDecorator = decorator
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)
		let transfer = SuspendedTransfer()
		provider.transferHook = transfer.run
		let download = Task {
			try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL, progress: progress, onTaskCreation: nil)
		}
		await fulfillment(of: [transfer.suspended], timeout: testWaitTimeout)
		transfer.resume(with: .failure(CloudProviderError.noInternetConnection))
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
		}
		XCTAssertLessThan(progress.fractionCompleted, 1)
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testDownloadFileWithFailingCleartextMetadata() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
		cryptor.decryptContentHook = { ciphertextURL, cleartextURL in
			temporaryURLs.withLock { $0 = [ciphertextURL, cleartextURL] }
		}
		cryptor.decryptFileNameError = CryptorMockError.notMocked
		await XCTAssertThrowsErrorAsync(try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL)) { error in
			XCTAssertEqual(CryptorMockError.notMocked, error as? CryptorMockError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
		assertDeleted(temporaryURLs.withLock { $0 })
	}

	func testDownloadFileWithCancellationBeforePublication() async throws {
		let decorator: VaultFormat6ProviderDecorator = decorator
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
		cryptor.decryptContentHook = { ciphertextURL, cleartextURL in
			temporaryURLs.withLock { $0 = [ciphertextURL, cleartextURL] }
			withUnsafeCurrentTask { $0?.cancel() }
		}
		let download = Task {
			try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL)
		}
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
		assertDeleted(temporaryURLs.withLock { $0 })
	}

	func testDownloadFileWithDestinationCreatedDuringDownload() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)
		let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
		cryptor.decryptContentHook = { ciphertextURL, cleartextURL in
			temporaryURLs.withLock { $0 = [ciphertextURL, cleartextURL] }
			try "other".write(to: localURL, atomically: true, encoding: .utf8)
		}
		await XCTAssertThrowsErrorAsync(try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL, progress: progress, onTaskCreation: nil)) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
		XCTAssertEqual("other", try String(contentsOf: localURL, encoding: .utf8))
		XCTAssertLessThan(progress.fractionCompleted, 1)
		assertDeleted(temporaryURLs.withLock { $0 })
	}

	func testDownloadFileWithCancellationDuringDecryption() async throws {
		let cryptor = try Cryptor(masterkey: Masterkey.createNew(), scheme: .sivCtrMac)
		let cloudPath = CloudPath("/File")
		let cleartextURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try Data(count: 1024 * 1024).write(to: cleartextURL)
		let uploadProvider = CloudProviderMock(folders: [], files: [:])
		_ = try await VaultFormat6ProviderDecorator(delegate: uploadProvider, vaultPath: vaultPath, cryptor: cryptor).uploadFile(from: cleartextURL, to: cloudPath, replaceExisting: false)
		let provider = CloudProviderMock(folders: [], files: uploadProvider.createdFiles)
		let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)
		// The transfer makes up the first 79.9 % of the progress, the decryption the following 20 %.
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			if progress.fractionCompleted > 0.8 {
				withUnsafeCurrentTask { $0?.cancel() }
			}
		}
		let download = Task {
			try await decorator.downloadFile(from: cloudPath, to: localURL, progress: progress, onTaskCreation: nil)
		}
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		progressObserver.invalidate()
		XCTAssertLessThan(progress.fractionCompleted, 0.9, "The decryption must not have finished")
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
		XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path))
	}

	func testUploadFile() async throws {
		let decorator: VaultFormat6ProviderDecorator = decorator
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
		let progress = Progress(totalUnitCount: 1)
		let transfer = SuspendedTransfer()
		provider.transferHook = transfer.run
		let upload = Task {
			try await decorator.uploadFile(from: localURL, to: CloudPath("/File 1"), replaceExisting: false, progress: progress, onTaskCreation: nil)
		}
		await fulfillment(of: [transfer.suspended], timeout: testWaitTimeout)
		XCTAssertGreaterThan(progress.fractionCompleted, 0)
		XCTAssertLessThan(progress.fractionCompleted, 1)
		transfer.resume()
		let metadata = try await value(of: upload)
		XCTAssertEqual(1, progress.fractionCompleted)
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual(Data("ciphertext1".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1"])
		XCTAssertEqual("File 1", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 1", metadata.cloudPath.path)
		XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path))
	}

	func testUploadFileWithFailingTransfer() async throws {
		let decorator: VaultFormat6ProviderDecorator = decorator
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
		let progress = Progress(totalUnitCount: 1)
		let transfer = SuspendedTransfer()
		provider.transferHook = transfer.run
		let upload = Task {
			try await decorator.uploadFile(from: localURL, to: CloudPath("/File 1"), replaceExisting: false, progress: progress, onTaskCreation: nil)
		}
		await fulfillment(of: [transfer.suspended], timeout: testWaitTimeout)
		transfer.resume(with: .failure(CloudProviderError.quotaInsufficient))
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertEqual(CloudProviderError.quotaInsufficient, error as? CloudProviderError)
		}
		XCTAssertLessThan(progress.fractionCompleted, 1)
	}

	func testUploadFileWithCancellationAfterEncryption() async throws {
		let decorator: VaultFormat6ProviderDecorator = decorator
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
		let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
		cryptor.encryptContentHook = { _, ciphertextURL in
			temporaryURLs.withLock { $0 = [ciphertextURL] }
			withUnsafeCurrentTask { $0?.cancel() }
		}
		let upload = Task {
			try await decorator.uploadFile(from: localURL, to: CloudPath("/File 1"), replaceExisting: false)
		}
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertFalse(provider.calls.contains("uploadFile"))
		assertDeleted(temporaryURLs.withLock { $0 })
	}

	func testUploadFileWithCancellationDuringEncryption() async throws {
		let cryptor = try Cryptor(masterkey: Masterkey.createNew(), scheme: .sivCtrMac)
		let provider = CloudProviderMock(folders: [], files: [:])
		let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try Data(count: 1024 * 1024).write(to: localURL)
		let progress = Progress(totalUnitCount: 1)
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			if progress.fractionCompleted > 0 {
				withUnsafeCurrentTask { $0?.cancel() }
			}
		}
		let upload = Task {
			try await decorator.uploadFile(from: localURL, to: CloudPath("/File"), replaceExisting: false, progress: progress, onTaskCreation: nil)
		}
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		progressObserver.invalidate()
		// The encryption makes up the first 20 % of the progress.
		XCTAssertLessThan(progress.fractionCompleted, 0.2, "The encryption must not have finished")
		XCTAssertFalse(provider.calls.contains("uploadFile"))
		XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path))
	}

	func testCreateFolder() async throws {
		try await decorator.createFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(2, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertNotNil(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"])
	}

	func testCreateFolderWithCancellationBeforeFirstRemoteChange() async throws {
		let decorator: VaultFormat6ProviderDecorator = decorator
		provider.metadataHook = { _ in
			withUnsafeCurrentTask { $0?.cancel() }
		}
		let creation = Task {
			try await decorator.createFolder(at: CloudPath("/Directory 1"))
		}
		await XCTAssertThrowsErrorAsync(try await value(of: creation)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertTrue(creation.isCancelled)
		XCTAssertTrue(provider.createdFolders.isEmpty)
		XCTAssertTrue(provider.createdFiles.isEmpty)
	}

	func testCreateFolderWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat6ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.createFolder(at: CloudPath("/Directory 1"))
		}
		XCTAssertEqual(["pathToVault/d/99", "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"], provider.createdFolders.sorted())
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"], Array(provider.createdFiles.keys))
		XCTAssertNotNil(try decorator.dirIdCache.get(CloudPath("/Directory 1")))
	}

	func testDeleteFile() async throws {
		try await decorator.deleteFile(at: CloudPath("/Directory 1/File 3"))
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3"))
	}

	func testDeleteFolder() async throws {
		try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(3, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"))
	}

	func testDeleteFolderWithoutSubDirs() async throws {
		try await decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2"))
		XCTAssertEqual(2, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2"))
	}

	func testDeleteFolderWithPagedItemList() async throws {
		let pagingProvider = VaultFormat6CloudProviderMock(folders: provider.folders, files: provider.files, maxPageSize: 1)
		let decorator = try VaultFormat6ProviderDecorator(delegate: pagingProvider, vaultPath: vaultPath, cryptor: cryptor)
		try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"], pagingProvider.deleted.sorted())
	}

	func testDeleteFolderWithMissingDirFile() async throws {
		// pathToVault
		// └─Directory 1
		//   ├─ Directory 2
		//   └─ File 3
		let folders: Set = [
			"pathToVault",
			"pathToVault/d",
			"pathToVault/d/00",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
			"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
		]
		let files = [
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": Data("dir2-id".utf8),
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3": Data("ciphertext3".utf8)
		]

		let provider = VaultFormat6CloudProviderMock(folders: folders, files: files)
		let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"))
	}

	func testDeleteFolderWithBrokenFolder() async throws {
		let folders: Set = [
			"pathToVault",
			"pathToVault/d",
			"pathToVault/d/00",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
		]
		let files = [
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1": Data("dir1-id".utf8)
		]
		let provider = VaultFormat6CloudProviderMock(folders: folders, files: files)
		let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"))
	}

	func testDeleteFolderWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat6ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		}
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"], provider.deleted.sorted())
		XCTAssertNil(try decorator.dirIdCache.get(CloudPath("/Directory 1")))
	}

	func testMoveFile() async throws {
		try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/Directory 1/File 2"))
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file2", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1"])
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(decorator)
		XCTAssertEqual([], provider.calls)
	}

	// MARK: - Internal

	func assertDeleted(_ temporaryURLs: [URL], file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertFalse(temporaryURLs.isEmpty, file: file, line: line)
		for temporaryURL in temporaryURLs {
			XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path), file: file, line: line)
		}
	}
}
