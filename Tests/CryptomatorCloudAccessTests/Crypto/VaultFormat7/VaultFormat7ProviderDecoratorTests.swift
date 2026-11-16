//
//  VaultFormat7ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import os
import XCTest
@testable import CryptomatorCloudAccessCore

class VaultFormat7ProviderDecoratorTests: XCTestCase {
	let vaultPath = CloudPath("pathToVault")
	let cryptor = VaultFormat7CryptorMock()
	var tmpDirURL: URL!
	var provider: VaultFormat7CloudProviderMock!
	var decorator: VaultFormat7ProviderDecorator!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		provider = VaultFormat7CloudProviderMock()
		decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
	}

	override func tearDownWithError() throws {
		decorator = nil
		provider = nil
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testTemporaryDirectoryLiesInProcessFolder() throws {
		XCTAssertEqual(try ProcessTemporaryDirectory.shared.directoryURL().path, decorator.tmpDirURL.deletingLastPathComponent().path)
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

	func testFetchItemListSkipsNamesThatAreNoSinglePathComponent() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: ["\(dirPath)/nested.c9r": Data(), "\(dirPath)/parent.c9r": Data(), "\(dirPath)/file1.c9r": Data()])
		let cryptor = CryptorMock(dirIds: ["": "00AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"], fileNames: ["nested": "a/b", "parent": "..", "file1": "File 1"], contents: [:])
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		XCTAssertEqual([CloudPath("/File 1")], itemList.items.map(\.cloudPath))
	}

	func testDownloadFile() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
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
		let decorator: VaultFormat7ProviderDecorator = decorator
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
		let decorator: VaultFormat7ProviderDecorator = decorator
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
		_ = try await VaultFormat7ProviderDecorator(delegate: uploadProvider, vaultPath: vaultPath, cryptor: cryptor).uploadFile(from: cleartextURL, to: cloudPath, replaceExisting: false)
		let provider = CloudProviderMock(folders: [], files: uploadProvider.createdFiles)
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
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
		let decorator: VaultFormat7ProviderDecorator = decorator
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
		XCTAssertEqual(Data("ciphertext1".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"])
		XCTAssertEqual("File 1", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 1", metadata.cloudPath.path)
		XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path))
	}

	func testUploadFileWithFailingTransfer() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
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
		let decorator: VaultFormat7ProviderDecorator = decorator
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
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
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
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertNotNil(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r"])
	}

	func testCreateFolderWithCancellationBeforeFirstRemoteChange() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
		provider.transferHook = { _, _ in
			withUnsafeCurrentTask { $0?.cancel() }
		}
		let creation = Task {
			try await decorator.createFolder(at: CloudPath("/Directory 1/Directory 1"))
		}
		await XCTAssertThrowsErrorAsync(try await value(of: creation)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertTrue(creation.isCancelled)
		XCTAssertTrue(provider.createdFolders.isEmpty)
		XCTAssertTrue(provider.createdFiles.isEmpty)
	}

	func testCreateFolderWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.createFolder(at: CloudPath("/Directory 1"))
		}
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", "pathToVault/d/99", "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"], provider.createdFolders.sorted())
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r"], Array(provider.createdFiles.keys))
		XCTAssertNotNil(try decorator.dirIdCache.get(CloudPath("/Directory 1")))
	}

	func testDeleteFile() async throws {
		try await decorator.deleteFile(at: CloudPath("/Directory 1/File 3"))
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r"))
	}

	func testDeleteFolder() async throws {
		try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(3, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
	}

	func testDeleteFolderWithoutSubDirs() async throws {
		try await decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2"))
		XCTAssertEqual(2, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r"))
	}

	func testDeleteFolderWithPagedItemList() async throws {
		let files = provider.files.merging(["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/a.c9r": Data()]) { $1 }
		let pagingProvider = VaultFormat7CloudProviderMock(folders: provider.folders, files: files, maxPageSize: 1)
		let decorator = try VaultFormat7ProviderDecorator(delegate: pagingProvider, vaultPath: vaultPath, cryptor: cryptor)
		try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"], pagingProvider.deleted.sorted())
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
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r",
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r",
			"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
		]
		let files = [
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r/dir.c9r": Data("dir2-id".utf8),
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r": Data("ciphertext3".utf8)
		]
		let provider = VaultFormat7CloudProviderMock(folders: folders, files: files)
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
	}

	func testDeleteFolderWithBrokenFolder() async throws {
		let folders: Set = [
			"pathToVault",
			"pathToVault/d",
			"pathToVault/d/00",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"
		]
		let files = [
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r": Data("dir1-id".utf8)
		]
		let provider = VaultFormat7CloudProviderMock(folders: folders, files: files)
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
	}

	func testDeleteFolderWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		}
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"], provider.deleted.sorted())
		XCTAssertNil(try decorator.dirIdCache.get(CloudPath("/Directory 1")))
	}

	func testDeleteFolderWithDeletionIncompleteKeepsReference() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"])
		await XCTAssertThrowsErrorAsync(try await decorator.deleteFolder(at: CloudPath("/Directory 1"))) { error in
			XCTAssertEqual(CloudProviderError.deletionIncomplete, error as? CloudProviderError)
		}
		XCTAssertFalse(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		XCTAssertEqual(Data("dir1-id".utf8), try decorator.dirIdCache.get(CloudPath("/Directory 1")))
	}

	/// The sibling `Directory 3` is deleted, which would let `allSettled` skip an ordinary failure of `Directory 2`. The refusal of `Directory 4` must still keep its ancestors.
	func testDeleteFolderWithRefusedNestedSubdirectoryKeepsAncestors() async throws {
		let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir3.c9r": "dir3-id", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/dir4.c9r": "dir4-id"])
		provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"])
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		await XCTAssertThrowsErrorAsync(try await decorator.deleteFolder(at: CloudPath("/Directory 1"))) { error in
			XCTAssertEqual(CloudProviderError.deletionIncomplete, error as? CloudProviderError)
		}
		XCTAssertEqual(["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"], provider.deleted.sorted())
	}

	/// A refusal settles as a value, so `allSettled` skips the other subdirectory's failure and the refusal decides the outcome.
	func testDeleteFolderWithRefusedAndFailedSubdirectoryOnSamePageThrowsDeletionIncomplete() async throws {
		let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir3.c9r": "dir3-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir4.c9r": "dir4-id"])
		provider.afterMutationHook = { call, cloudPath in
			guard call == "deleteFolder" else {
				return
			}
			switch cloudPath.path {
			case "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC": throw CloudProviderError.deletionIncomplete
			case "pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD": throw CloudProviderError.unauthorized
			default: break
			}
		}
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		await XCTAssertThrowsErrorAsync(try await decorator.deleteFolder(at: CloudPath("/Directory 1"))) { error in
			XCTAssertEqual(CloudProviderError.deletionIncomplete, error as? CloudProviderError)
		}
		XCTAssertFalse(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
		XCTAssertFalse(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
	}

	func testDeleteFolderWithRefusalThenLaterPageListingFailureThrowsDeletionIncomplete() async throws {
		let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id"], files: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r": Data()], maxPageSize: 1)
		provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
		provider.listingHook = { cloudPath, pageToken in
			if cloudPath.path == "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", pageToken != nil {
				throw CloudProviderError.unauthorized
			}
		}
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		await XCTAssertThrowsErrorAsync(try await decorator.deleteFolder(at: CloudPath("/Directory 1"))) { error in
			XCTAssertEqual(CloudProviderError.deletionIncomplete, error as? CloudProviderError)
		}
		XCTAssertEqual(["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"], provider.deleted)
	}

	/// A listing also fails with `itemNotFound` for a missing name file while the directory exists, which must neither count as deleted nor let the folder's `.c9r` be deleted.
	func testDeleteFolderWithItemNotFoundFromExistingSubdirectoryKeepsParent() async throws {
		let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id"])
		provider.listingHook = { cloudPath, _ in
			if cloudPath.path == "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" {
				throw CloudProviderError.itemNotFound
			}
		}
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		await XCTAssertThrowsErrorAsync(try await decorator.deleteFolder(at: CloudPath("/Directory 1"))) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
		XCTAssertEqual([], provider.deleted)
	}

	/// A refused delete leaves the reference to a subdirectory whose directory is already gone, which a later delete counts as deleted. Listing a missing directory fails, as with a real provider.
	func testDeleteFolderRetryAfterRefusedFinalDeleteFinishes() async throws {
		let fixture = VaultFormat7CloudProviderMock()
		let provider = VaultFormat7CloudProviderMock(folders: fixture.folders.subtracting(["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"]), files: fixture.files)
		provider.listingHook = { cloudPath, _ in
			if cloudPath.path == "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" {
				throw CloudProviderError.itemNotFound
			}
		}
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"], provider.deleted.sorted())
	}

	func testMoveFolderWithMoveCompletedUpdatesCacheAndRethrows() async throws {
		try decorator.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir1-id".utf8))
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		await XCTAssertThrowsErrorAsync(try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
		XCTAssertEqual(Data("dir1-id".utf8), try decorator.dirIdCache.get(CloudPath("/Directory 2")))
		XCTAssertNil(try decorator.dirIdCache.get(CloudPath("/Directory 1")))
	}

	/// A move that failed otherwise left no usable target, so the cache must not map one.
	func testMoveFolderWithOtherMoveErrorSkipsCacheUpdate() async throws {
		try decorator.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir1-id".utf8))
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.itemAlreadyExists)
		await XCTAssertThrowsErrorAsync(try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2"))) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
		XCTAssertNil(try decorator.dirIdCache.get(CloudPath("/Directory 2")))
		XCTAssertEqual(Data("dir1-id".utf8), try decorator.dirIdCache.get(CloudPath("/Directory 1")))
	}

	func testMoveFile() async throws {
		try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/Directory 1/File 2"))
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file2.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"])
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(decorator)
		XCTAssertEqual([], provider.calls)
	}

	// MARK: - Internal

	/// Returns a provider whose `Directory 1` holds the given subdirectory references, by path below `pathToVault/d` and dir ID. The directories of `dir1-id` to `dir4-id` exist.
	func makeNestedProvider(subdirectories: [String: String], files: [String: Data] = [:], maxPageSize: Int = .max) -> CloudProviderMock {
		let directories = ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"]
		let references = ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r": "dir1-id"].merging(subdirectories) { $1 }
		let folders = Set(["pathToVault", "pathToVault/d"] + (directories + references.keys).map { "pathToVault/d/\($0)" })
		let dirFiles = Dictionary(uniqueKeysWithValues: references.map { ("pathToVault/d/\($0.key)/dir.c9r", Data($0.value.utf8)) })
		return CloudProviderMock(folders: folders, files: dirFiles.merging(files) { $1 }, maxPageSize: maxPageSize)
	}

	func assertDeleted(_ temporaryURLs: [URL], file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertFalse(temporaryURLs.isEmpty, file: file, line: line)
		for temporaryURL in temporaryURLs {
			XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path), file: file, line: line)
		}
	}
}
