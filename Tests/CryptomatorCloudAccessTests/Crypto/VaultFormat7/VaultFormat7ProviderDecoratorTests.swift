//
//  VaultFormat7ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

/// The decorator of a test, stacked onto a fresh vault mock directly or through the shortening decorator.
struct VaultFormat7Fixture {
	let provider = VaultFormat7CloudProviderMock()
	let shorteningDecorator: VaultFormat7ShorteningProviderDecorator?
	let decorator: VaultFormat7ProviderDecorator

	init(stacking: Stacking, vaultPath: CloudPath, cryptor: VaultFormat7CryptorMock) throws {
		switch stacking {
		case .plain:
			self.shorteningDecorator = nil
			self.decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		case .shortening:
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			self.shorteningDecorator = shorteningDecorator
			self.decorator = try VaultFormat7ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
		}
	}
}

extension UnitTests {
	final class VaultFormat7ProviderDecoratorTests {
		let vaultPath = CloudPath("pathToVault")
		let cryptor = VaultFormat7CryptorMock()
		let tmpDirURL: URL

		init() throws {
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test(arguments: Stacking.allCases)
		func temporaryDirectoryLiesInProcessFolder(stacking: Stacking) throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			#expect(try ProcessTemporaryDirectory.shared.directoryURL().path == decorator.tmpDirURL.deletingLastPathComponent().path)
			if stacking == .shortening {
				let shorteningDecorator = try #require(fixture.shorteningDecorator)
				#expect(try ProcessTemporaryDirectory.shared.directoryURL().path == shorteningDecorator.tmpDirURL.deletingLastPathComponent().path)
			}
		}

		@Test(arguments: Stacking.allCases)
		func testFetchItemMetadata(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			let metadata = try await decorator.fetchItemMetadata(at: CloudPath("/Directory 1/File 3"))
			#expect(metadata.name == "File 3")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/Directory 1/File 3")
		}

		@Test(arguments: Stacking.allCases)
		func fetchItemListForRootDir(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			switch stacking {
			case .plain:
				#expect(itemList.items.count == 3)
				#expect(itemList.items.contains(where: { $0.name == "File 1" }))
				#expect(itemList.items.contains(where: { $0.name == "File 2" }))
				#expect(itemList.items.contains(where: { $0.name == "Directory 1" }))
			case .shortening:
				#expect(itemList.items.count == 6)
				#expect(itemList.items.contains(where: { $0.name == "Directory 1" }))
				#expect(itemList.items.contains(where: { $0.name == "Directory 3 (Long)" }))
				#expect(itemList.items.contains(where: { $0.name == "File 1" }))
				#expect(itemList.items.contains(where: { $0.name == "File 2" }))
				#expect(itemList.items.contains(where: { $0.name == "File 4 (Long)" }))
				#expect(itemList.items.contains(where: { $0.name == "File 5 (Long)" }))
			}
		}

		@Test(arguments: Stacking.allCases)
		func fetchItemListForSubDir(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1"), withPageToken: nil)
			#expect(itemList.items.count == 2)
			#expect(itemList.items.contains(where: { $0.name == "File 3" }))
			#expect(itemList.items.contains(where: { $0.name == "Directory 2" }))
		}

		@Test(arguments: Stacking.allCases)
		func fetchItemListForEmptyDir(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1/Directory 2"), withPageToken: nil)
			#expect(itemList.items.isEmpty)
		}

		@Test
		func fetchItemListSkipsNamesThatAreNoSinglePathComponent() async throws {
			let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: ["\(dirPath)/nested.c9r": Data(), "\(dirPath)/parent.c9r": Data(), "\(dirPath)/file1.c9r": Data()])
			let cryptor = CryptorMock(dirIds: ["": "00AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"], fileNames: ["nested": "a/b", "parent": "..", "file1": "File 1"], contents: [:])
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect([CloudPath("/File 1")] == itemList.items.map(\.cloudPath))
		}

		@Test
		func fetchItemListWithTooLargeDirFileThrowsInvalidDirectoryReference() async throws {
			let provider = makeNestedProvider(subdirectories: ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r": String(repeating: "a", count: vaultDirFileMaxLength + 1)])
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1"), withPageToken: nil) }
		}

		@Test(arguments: Stacking.allCases)
		func testDownloadFile(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let progress = Progress(totalUnitCount: 1)
			let transfer = SuspendedTransfer()
			provider.transferHook = transfer.run
			let download = Task {
				try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL, progress: progress, onTaskCreation: nil)
			}
			await transfer.suspended.wait()
			#expect(progress.fractionCompleted > 0)
			#expect(progress.fractionCompleted < 1)
			transfer.resume()
			let metadata = try await cancellingValue(of: download)
			#expect(progress.fractionCompleted == 1)
			let cleartext = try String(contentsOf: localURL, encoding: .utf8)
			#expect(cleartext == "cleartext1")
			#expect(metadata.name == "File 1")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/File 1")
			#expect(provider.lastModifiedDate == metadata.lastModifiedDate)
			#expect(metadata.size == 10)
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		@Test(arguments: Stacking.allCases)
		func downloadFileWithFailingTransfer(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let progress = Progress(totalUnitCount: 1)
			let transfer = SuspendedTransfer()
			provider.transferHook = transfer.run
			let download = Task {
				try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL, progress: progress, onTaskCreation: nil)
			}
			await transfer.suspended.wait()
			transfer.resume(with: .failure(CloudProviderError.noInternetConnection))
			await #expect(throws: CloudProviderError.noInternetConnection) { try await cancellingValue(of: download) }
			#expect(progress.fractionCompleted < 1)
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test(arguments: Stacking.allCases)
		func downloadFileWithFailingCleartextMetadata(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
			cryptor.decryptContentHook = { ciphertextURL, cleartextURL in
				temporaryURLs.withLock { $0 = [ciphertextURL, cleartextURL] }
			}
			cryptor.decryptFileNameError = CryptorMockError.notMocked
			await #expect(throws: CryptorMockError.notMocked) { try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL) }
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
			assertDeleted(temporaryURLs.withLock { $0 })
		}

		@Test(arguments: Stacking.allCases)
		func downloadFileWithCancellationBeforePublication(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
			cryptor.decryptContentHook = { ciphertextURL, cleartextURL in
				temporaryURLs.withLock { $0 = [ciphertextURL, cleartextURL] }
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let download = Task {
				try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
			assertDeleted(temporaryURLs.withLock { $0 })
		}

		@Test(arguments: Stacking.allCases)
		func downloadFileWithDestinationCreatedDuringDownload(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let progress = Progress(totalUnitCount: 1)
			let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
			cryptor.decryptContentHook = { ciphertextURL, cleartextURL in
				temporaryURLs.withLock { $0 = [ciphertextURL, cleartextURL] }
				try "other".write(to: localURL, atomically: true, encoding: .utf8)
			}
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL, progress: progress, onTaskCreation: nil) }
			#expect(try String(contentsOf: localURL, encoding: .utf8) == "other")
			#expect(progress.fractionCompleted < 1)
			assertDeleted(temporaryURLs.withLock { $0 })
		}

		@Test
		func downloadFileWithCancellationDuringDecryption() async throws {
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
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }
			progressObserver.invalidate()
			#expect(progress.fractionCompleted < 0.9, "The decryption must not have finished")
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		@Test(arguments: Stacking.allCases)
		func testUploadFile(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
			let progress = Progress(totalUnitCount: 1)
			let transfer = SuspendedTransfer()
			provider.transferHook = transfer.run
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File 1"), replaceExisting: false, progress: progress, onTaskCreation: nil)
			}
			await transfer.suspended.wait()
			#expect(progress.fractionCompleted > 0)
			#expect(progress.fractionCompleted < 1)
			transfer.resume()
			let metadata = try await cancellingValue(of: upload)
			#expect(progress.fractionCompleted == 1)
			#expect(provider.createdFiles.count == 1)
			#expect(Data("ciphertext1".utf8) == provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"])
			#expect(metadata.name == "File 1")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/File 1")
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		@Test(arguments: Stacking.allCases)
		func uploadFileWithFailingTransfer(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
			let progress = Progress(totalUnitCount: 1)
			let transfer = SuspendedTransfer()
			provider.transferHook = transfer.run
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File 1"), replaceExisting: false, progress: progress, onTaskCreation: nil)
			}
			await transfer.suspended.wait()
			transfer.resume(with: .failure(CloudProviderError.quotaInsufficient))
			await #expect(throws: CloudProviderError.quotaInsufficient) { try await cancellingValue(of: upload) }
			#expect(progress.fractionCompleted < 1)
		}

		@Test(arguments: Stacking.allCases)
		func uploadFileWithCancellationAfterEncryption(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
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
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }
			#expect(!provider.calls.contains("uploadFile"))
			assertDeleted(temporaryURLs.withLock { $0 })
		}

		@Test
		func uploadFileWithCancellationDuringEncryption() async throws {
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
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }
			progressObserver.invalidate()
			// The encryption makes up the first 20 % of the progress.
			#expect(progress.fractionCompleted < 0.2, "The encryption must not have finished")
			#expect(!provider.calls.contains("uploadFile"))
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		/// cryptolib sizes the encryption progress from the attributes of the URL it gets, which don't follow a symbolic link.
		@Test
		func uploadFileThroughSymbolicLinkEncryptsTarget() async throws {
			let fixture = try VaultFormat7Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			let targetURL = tmpDirURL.appendingPathComponent("target", isDirectory: false)
			try "cleartext1".write(to: targetURL, atomically: true, encoding: .utf8)
			let linkURL = tmpDirURL.appendingPathComponent("link", isDirectory: false)
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
			let encryptedURLs = OSAllocatedUnfairLock(initialState: [URL]())
			cryptor.encryptContentHook = { cleartextURL, _ in
				encryptedURLs.withLock { $0.append(cleartextURL) }
			}
			_ = try await fixture.decorator.uploadFile(from: linkURL, to: CloudPath("/File 1"), replaceExisting: false)
			#expect(encryptedURLs.withLock { $0 }.map(\.lastPathComponent) == ["target"])
		}

		@Test(arguments: [false, true])
		func uploadFileFromUnusableSourceThrowsBeforeAnyRequest(sourceIsFolder: Bool) async throws {
			let fixture = try VaultFormat7Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			let sourceURL = sourceIsFolder ? tmpDirURL : tmpDirURL.appendingPathComponent("link", isDirectory: false)
			if !sourceIsFolder {
				try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: tmpDirURL.appendingPathComponent("missing", isDirectory: false))
			}
			await #expect(throws: sourceIsFolder ? CloudProviderError.itemTypeMismatch : .itemNotFound) {
				try await fixture.decorator.uploadFile(from: sourceURL, to: CloudPath("/Directory 1/File"), replaceExisting: false)
			}
			#expect(fixture.provider.calls == [])
		}

		@Test(arguments: Stacking.allCases)
		func testCreateFolder(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await decorator.createFolder(at: CloudPath("/Directory 1"))
			#expect(provider.createdFolders.count == 3)
			#expect(provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
			#expect(provider.createdFolders.contains("pathToVault/d/99"))
			#expect(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
			#expect(provider.createdFiles.count == 1)
			#expect(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r"] != nil)
		}

		@Test(arguments: Stacking.allCases)
		func createFolderWithCancellationBeforeFirstRemoteChange(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			provider.transferHook = { _, _ in
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let creation = Task {
				try await decorator.createFolder(at: CloudPath("/Directory 1/Directory 1"))
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: creation) }
			#expect(creation.isCancelled)
			#expect(provider.createdFolders.isEmpty)
			#expect(provider.createdFiles.isEmpty)
		}

		@Test(arguments: Stacking.allCases)
		func createFolderWithCancellationAfterFirstRemoteChange(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.createFolder(at: CloudPath("/Directory 1"))
			}
			#expect(provider.createdFolders.sorted() == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", "pathToVault/d/99", "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"])
			#expect(Array(provider.createdFiles.keys) == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r"])
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) != nil)
		}

		@Test(arguments: Stacking.allCases)
		func testDeleteFile(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await decorator.deleteFile(at: CloudPath("/Directory 1/File 3"))
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r"))
		}

		@Test(arguments: Stacking.allCases)
		func testDeleteFolder(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted.count == 3)
			#expect(provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
			#expect(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
			#expect(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		}

		@Test(arguments: Stacking.allCases)
		func deleteFolderWithoutSubDirs(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2"))
			#expect(provider.deleted.count == 2)
			#expect(provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
			#expect(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r"))
		}

		@Test
		func deleteFolderWithPagedItemList() async throws {
			let fixture = VaultFormat7CloudProviderMock()
			let files = fixture.files.merging(["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/a.c9r": Data()]) { $1 }
			let pagingProvider = VaultFormat7CloudProviderMock(folders: fixture.folders, files: files, maxPageSize: 1)
			let decorator = try VaultFormat7ProviderDecorator(delegate: pagingProvider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(pagingProvider.deleted.sorted() == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
		}

		@Test
		func deleteFolderWithMissingDirFile() async throws {
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
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		}

		@Test
		func deleteFolderWithBrokenFolder() async throws {
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
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		}

		@Test(arguments: Stacking.allCases)
		func deleteFolderWithCancellationAfterFirstRemoteChange(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			}
			#expect(provider.deleted.sorted() == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		@Test(arguments: Stacking.allCases)
		func deleteFolderWithDeletionIncompleteKeepsReference(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"])
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(!provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
			#expect(try Data("dir1-id".utf8) == decorator.dirIdCache.get(CloudPath("/Directory 1")))
		}

		/// The refusal of `Directory 4` keeps its ancestors although its parent's sibling `Directory 3` is deleted.
		@Test
		func deleteFolderWithRefusedNestedSubdirectoryKeepsAncestors() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir3.c9r": "dir3-id", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/dir4.c9r": "dir4-id"])
			provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"])
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted.sorted() == ["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"])
		}

		/// A refusal takes precedence over another subdirectory's failure.
		@Test
		func deleteFolderWithRefusedAndFailedSubdirectoryOnSamePageThrowsDeletionIncomplete() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir3.c9r": "dir3-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir4.c9r": "dir4-id"])
			provider.afterMutationHook = { call, cloudPath in
				guard call == "deleteFolder" else {
					return
				}
				switch cloudPath.path {
				case "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC": throw CloudProviderError.deletionIncomplete
				case "pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD": throw CloudProviderError.quotaInsufficient
				default: break
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(!provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
			#expect(!provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		}

		@Test
		func deleteFolderWithRefusalThenLaterPageListingFailureThrowsDeletionIncomplete() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id"], files: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r": Data()], maxPageSize: 1)
			provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
			provider.listingHook = { cloudPath, pageToken in
				if cloudPath.path == "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", pageToken != nil {
					throw CloudProviderError.unauthorized
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == ["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
		}

		/// A listing also fails with `itemNotFound` for a missing name file while the directory exists, which must neither count as deleted nor let the folder's `.c9r` be deleted.
		@Test
		func deleteFolderWithItemNotFoundFromExistingSubdirectoryKeepsParent() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id"])
			provider.listingHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" {
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == [])
		}

		/// The unlistable `Directory 4` keeps its ancestors although its parent's sibling `Directory 3` is deleted.
		@Test
		func deleteFolderWithUnlistableNestedSubdirectoryKeepsAncestors() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir3.c9r": "dir3-id", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/dir4.c9r": "dir4-id"])
			provider.listingHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE" {
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == ["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"])
		}

		@Test
		func deleteFolderWithUnlistableSubdirectoryThenLaterPageListingFailureThrowsItemNotFound() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id"], files: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r": Data()], maxPageSize: 1)
			provider.listingHook = { cloudPath, pageToken in
				switch (cloudPath.path, pageToken) {
				case ("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", _): throw CloudProviderError.itemNotFound
				case ("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", .some): throw CloudProviderError.unauthorized
				default: break
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == [])
		}

		/// When the directory of `Directory 2` lists with `itemTypeMismatch` but its metadata reports a folder, it exists but can't be listed, so the delete throws `itemNotFound`.
		@Test(arguments: zip([CloudProviderError.quotaInsufficient, .itemTypeMismatch], [CloudProviderError.quotaInsufficient, .itemNotFound]))
		func deleteFolderWithFailedSubdirectoryAndDeletedSiblingKeepsParent(failure: CloudProviderError, thrown: CloudProviderError) async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir3.c9r": "dir3-id"])
			provider.listingHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" {
					throw failure
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: thrown) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == ["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"])
		}

		@Test
		func deleteFolderWithFailedDirFileDownloadAndDeletedSiblingKeepsParent() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir3.c9r": "dir3-id"])
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r/dir.c9r" {
					throw CloudProviderError.quotaInsufficient
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.quotaInsufficient) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == ["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"])
		}

		/// The failure of `Directory 2` on the first page doesn't stop the delete, and the unlistable `Directory 3` on the second page takes precedence over it.
		@Test
		func deleteFolderWithFailedSubdirectoryThenUnlistableSubdirectoryOnLaterPageThrowsItemNotFound() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir3.c9r": "dir3-id"], maxPageSize: 1)
			provider.listingHook = { cloudPath, _ in
				switch cloudPath.path {
				case "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC": throw CloudProviderError.quotaInsufficient
				case "pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD": throw CloudProviderError.itemNotFound
				default: break
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == [])
		}

		/// The `itemNotFound` of the second page's listing takes precedence over the failure of `Directory 2` on the first page.
		@Test
		func deleteFolderWithFailedSubdirectoryThenLaterPageListingItemNotFoundThrowsItemNotFound() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id"], files: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r": Data()], maxPageSize: 1)
			provider.listingHook = { cloudPath, pageToken in
				switch (cloudPath.path, pageToken) {
				case ("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", _): throw CloudProviderError.quotaInsufficient
				case ("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", .some): throw CloudProviderError.itemNotFound
				default: break
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == [])
		}

		/// A refused delete leaves the reference to a subdirectory whose directory is already gone, which a later delete counts as deleted. Listing a missing directory fails, as with a real provider.
		@Test
		func deleteFolderRetryAfterRefusedFinalDeleteFinishes() async throws {
			let fixture = VaultFormat7CloudProviderMock()
			let provider = VaultFormat7CloudProviderMock(folders: fixture.folders.subtracting(["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"]), files: fixture.files)
			provider.listingHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" {
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted.sorted() == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"])
		}

		/// Every subfolder references the same directory, whose repeated deletes count as done.
		@Test
		func deleteFolderDownloadsAtMostLimitDirFilesAtOnce() async throws {
			let subfolderPathPrefix = "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/subfolder"
			let provider = makeNestedProvider(subdirectories: Dictionary(uniqueKeysWithValues: (1 ... vaultItemConcurrencyLimit + 2).map { ("11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/subfolder\($0).c9r", "dir2-id") }))
			let runningCount = OSAllocatedUnfairLock(initialState: 0)
			let gate = Gate()
			let limitStarted = TestSignal("limit of downloads started", expectedCount: vaultItemConcurrencyLimit, allowsOverFulfillment: true)
			let limitExceeded = TestSignal("more downloads than the limit ran at once", allowsOverFulfillment: true)
			provider.transferHook = { cloudPath, _ in
				guard cloudPath.path.hasPrefix(subfolderPathPrefix) else {
					return
				}
				let running = runningCount.withLock { count in
					count += 1
					return count
				}
				if running > vaultItemConcurrencyLimit {
					limitExceeded.fulfill()
				} else {
					limitStarted.fulfill()
				}
				await gate.wait()
				runningCount.withLock { $0 -= 1 }
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			let deletion = Task {
				try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			}

			await limitStarted.wait()
			await limitExceeded.expectNoFulfillment(within: .seconds(0.2))
			gate.open()

			try await cancellingValue(of: deletion)
			#expect(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		}

		/// A subfolder whose `name.c9s` can't be read is deleted with its parent, and the `.c9s` of a file holds no `dir.c9r` to follow.
		@Test
		func deleteFolderFollowsDirFilesOfC9SWithoutReadingNames() async throws {
			let folderC9SPath = "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/folder.c9s"
			let fileC9SPath = "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file.c9s"
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/folder.c9s": "dir2-id"], folders: [fileC9SPath], files: ["\(folderC9SPath)/name.c9s": Data(), "\(fileC9SPath)/contents.c9r": Data(), "\(fileC9SPath)/name.c9s": Data()])
			let downloadedNameFiles = OSAllocatedUnfairLock(initialState: [String]())
			provider.transferHook = { cloudPath, _ in
				if cloudPath.lastPathComponent == "name.c9s" {
					downloadedNameFiles.withLock { $0.append(cloudPath.path) }
					throw CloudProviderError.quotaInsufficient
				}
			}
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let decorator = try VaultFormat7ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"])
			#expect(downloadedNameFiles.withLock { $0 } == [])
		}

		/// Only a `.c9r` or `.c9s` folder is a Cryptomator item, so the directory of the `dir.c9r` in another folder isn't deleted.
		@Test
		func deleteFolderIgnoresDirFileOfOtherFolder() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/backup": "dir2-id"])
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"])
		}

		@Test
		func deleteFolderWithDirFileNamingAncestorThrowsInvalidDirectoryReference() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/dir5.c9r": "dir1-id"])
			let listedFolders = OSAllocatedUnfairLock(initialState: [String]())
			provider.listingHook = CloudProviderMock.listingEachFolderOnce(recordingInto: listedFolders)
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2")) }
			#expect(listedFolders.withLock { $0 } == ["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/dir5.c9r"])
			#expect(provider.deleted == [])
		}

		@Test
		func deleteFolderWithDirFileNamingFolderItselfThrowsInvalidDirectoryReference() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir1-id"])
			let listedFolders = OSAllocatedUnfairLock(initialState: [String]())
			provider.listingHook = CloudProviderMock.listingEachFolderOnce(recordingInto: listedFolders)
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(listedFolders.withLock { $0 } == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r"])
			#expect(provider.deleted == [])
		}

		/// `Directory 5` inside `Directory 3` refers to the directory of `Directory 2`, which contains both.
		@Test
		func deleteFolderWithDirFileCycleBelowFolderThrowsInvalidDirectoryReference() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/dir3.c9r": "dir3-id", "33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/dir5.c9r": "dir2-id"])
			let listedFolders = OSAllocatedUnfairLock(initialState: [String]())
			provider.listingHook = CloudProviderMock.listingEachFolderOnce(recordingInto: listedFolders)
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			let listed = listedFolders.withLock { $0 }
			#expect(Set(listed).count == listed.count)
			#expect(provider.deleted == [])
		}

		@Test(arguments: zip(["/Directory 1", "/Directory 1/Directory 2"], [["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r": ""], ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir1-id"]]))
		func deleteFolderWhoseDirFileNamesRootOrParentDeletesNothing(path: String, subdirectories: [String: String]) async throws {
			let provider = makeNestedProvider(subdirectories: subdirectories)
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.deleteFolder(at: CloudPath(path)) }
			#expect(!provider.calls.contains("fetchItemList"))
			#expect(provider.deleted == [])
		}

		/// The dir file of `Directory 1` names the root, so `Directory 2` would resolve to the root's `Directory 2`.
		@Test
		func deleteFolderBelowFolderWhoseDirFileNamesRootReadsNoFurtherDirFile() async throws {
			let provider = makeNestedProvider(subdirectories: ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r": "", "00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir2.c9r": "dir2-id"])
			let downloadedFiles = OSAllocatedUnfairLock(initialState: [String]())
			provider.transferHook = { cloudPath, _ in
				downloadedFiles.withLock { $0.append(cloudPath.path) }
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2")) }
			#expect(downloadedFiles.withLock { $0 } == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r"])
			#expect(provider.deleted == [])
		}

		/// Another device moved the folder away and created a new one at its path, which the cache doesn't know.
		@Test
		func deleteFolderWithStaleCachedDirIdDeletesNothingAndInvalidatesCache() async throws {
			let provider = VaultFormat7CloudProviderMock()
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			try decorator.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir2-id".utf8))
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(!provider.calls.contains("fetchItemList"))
			#expect(provider.deleted == [])
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) == nil)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted.sorted() == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
		}

		/// `File 1` doesn't exist in the directory of `Directory 1`, whose stale cached dir ID must still be detected.
		@Test
		func deleteMissingFolderBelowFolderWithStaleCachedDirIdInvalidatesCache() async throws {
			let provider = VaultFormat7CloudProviderMock()
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			try decorator.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir2-id".utf8))
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1/File 1")) }
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) == nil)
			#expect(!provider.calls.contains("deleteFolder"))
		}

		/// The first dir file read is that of the deleted folder itself, or that of its parent.
		@Test(arguments: ["/Directory 1", "/Directory 1/Directory 2"])
		func deleteFolderCancelledWhileReadingDirFileChangesNothing(path: String) async throws {
			let provider = VaultFormat7CloudProviderMock()
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			try decorator.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir2-id".utf8))
			let transfer = SuspendedTransfer()
			provider.transferHook = transfer.run
			let deletion = Task {
				try await decorator.deleteFolder(at: CloudPath(path))
			}
			await transfer.suspended.wait()
			let calls = provider.calls
			deletion.cancel()
			transfer.resume()
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: deletion) }
			#expect(provider.calls == calls)
			#expect(try Data("dir2-id".utf8) == decorator.dirIdCache.get(CloudPath("/Directory 1")))
		}

		/// A provider that addresses items by cached IDs reports a `dir.c9r` that another client replaced as missing, while the folder still lists it.
		@Test
		func deleteFolderWithUnreadableListedDirFileKeepsReference() async throws {
			let provider = VaultFormat7CloudProviderMock()
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r" {
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == [])
		}

		/// The listing of the `.c9r` is the last request before the delete, so a cancellation during it stops the delete, also when it finds a `dir.c9r`.
		@Test(arguments: [[], ["dir.c9r"]])
		func deleteFolderCancelledWhileListingFolderWithUnreadableDirFileThrowsCancellationError(files: [String]) async throws {
			let provider = makeBrokenFolderProvider(files: files)
			provider.transferHook = { _, _ in
				throw CloudProviderError.itemNotFound
			}
			provider.listingHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r" {
					withUnsafeCurrentTask { $0?.cancel() }
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			let deletion = Task {
				try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: deletion) }
			#expect(provider.deleted == [])
		}

		/// The `.c9s` of a long name is listed physically, so its unreadable `dir.c9r` keeps the reference, and a `.c9s` that a partial delete left with only `name.c9s` is deleted.
		@Test(arguments: [true, false])
		func deleteFolderWithLongNameWithoutReadableDirFile(holdsDirFile: Bool) async throws {
			let c9sPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"
			let fixture = VaultFormat7CloudProviderMock()
			let provider = CloudProviderMock(folders: fixture.folders, files: fixture.files.filter { holdsDirFile || $0.key != "\(c9sPath)/dir.c9r" })
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == "\(c9sPath)/dir.c9r" {
					throw CloudProviderError.itemNotFound
				}
			}
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let decorator = try VaultFormat7ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
			if holdsDirFile {
				await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)")) }
				#expect(provider.deleted == [])
			} else {
				try await decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)"))
				#expect(provider.deleted == [c9sPath])
			}
		}

		/// A `dir.c9r` folder holds no dir ID, so the walk doesn't follow it and the parent is deleted.
		@Test
		func deleteFolderWithSubfolderHoldingDirFolderDeletesParent() async throws {
			let provider = makeNestedProvider(subdirectories: [:], folders: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/sub.c9r", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/sub.c9r/dir.c9r"])
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"])
		}

		/// Only a `dir.c9r` file holds a dir ID, so a `.c9r` without one is deleted without a walk.
		@Test(arguments: zip([["symlink.c9r"], []], [[], ["dir.c9r"]]))
		func deleteFolderWithoutDirFileDeletesReference(files: [String], folders: [String]) async throws {
			let provider = makeBrokenFolderProvider(files: files, folders: folders)
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"])
		}

		/// The `dir.c9r` lies on the second page of the `.c9r`, whose listing may also fail.
		@Test(arguments: [false, true])
		func deleteFolderWithUnreadableDirFileOnLaterPageKeepsReference(laterPageFails: Bool) async throws {
			let provider = makeBrokenFolderProvider(files: ["aaa", "dir.c9r"], maxPageSize: 1)
			provider.transferHook = { _, _ in
				throw CloudProviderError.itemNotFound
			}
			provider.listingHook = { cloudPath, pageToken in
				if laterPageFails, cloudPath.path == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", pageToken != nil {
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == [])
		}

		/// The `dir.c9r` on the first page keeps the reference, whatever a later page would answer.
		@Test
		func deleteFolderWithUnreadableDirFileListedOnFirstPageRequestsNoFurtherPage() async throws {
			let provider = makeBrokenFolderProvider(files: ["dir.c9r", "zzz"], maxPageSize: 1)
			provider.transferHook = { _, _ in
				throw CloudProviderError.itemNotFound
			}
			let laterPageRequested = TestSignal("later page of the .c9r requested")
			provider.listingHook = { cloudPath, pageToken in
				if cloudPath.path == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", pageToken != nil {
					laterPageRequested.fulfill()
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(laterPageRequested.fulfillmentCount == 0)
			#expect(provider.deleted == [])
		}

		/// A file at the path of a folder's directory is deleted, and then the folder, as Cryptomator Desktop does.
		@Test(arguments: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
		func deleteFolderWithFileAtDirectoryPathDeletesFileAndFolder(strayFile: String) async throws {
			let strayFilePath = "pathToVault/d/\(strayFile)"
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id"], files: [strayFilePath: Data()])
			provider.metadataOverride = CloudProviderMock.reading([.file, nil], at: strayFilePath)
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted.first == strayFilePath)
			#expect(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
			#expect(provider.deleted.last == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r")
		}

		@Test(arguments: [CloudItemType.folder, .symlink, .unknown])
		func deleteFolderWithOtherItemAtDirectoryPathKeepsReference(itemType: CloudItemType) async throws {
			let provider = makeNestedProvider(subdirectories: [:], files: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB": Data()])
			provider.metadataOverride = CloudProviderMock.reading([itemType], at: "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(!provider.calls.contains("deleteFile"))
			#expect(provider.deleted == [])
		}

		/// On S3, a prefix holding objects can appear beside an object of the same name.
		@Test
		func deleteFolderWithDirectoryPathRemainingAfterFileDeleteKeepsReference() async throws {
			let provider = makeNestedProvider(subdirectories: [:], files: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB": Data()])
			provider.metadataOverride = CloudProviderMock.reading([.file, .folder], at: "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.calls == ["downloadFile", "fetchItemList", "fetchItemMetadata", "deleteFile", "fetchItemMetadata"])
			#expect(provider.deleted == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"])
		}

		/// The item at the path disappeared between its listing and its metadata read.
		@Test
		func deleteFolderWithDirectoryPathGoneAfterListingDeletesReference() async throws {
			let provider = makeNestedProvider(subdirectories: [:], files: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB": Data()])
			provider.metadataOverride = CloudProviderMock.reading([nil], at: "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.calls.contains("fetchItemMetadata"))
			#expect(provider.deleted == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"])
		}

		@Test
		func deleteFolderWithRefusedFileDeleteAtDirectoryPathKeepsReference() async throws {
			let provider = makeNestedProvider(subdirectories: [:], files: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB": Data()])
			provider.metadataOverride = CloudProviderMock.reading([.file], at: "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
			provider.afterMutationHook = CloudProviderMock.failing("deleteFile", with: CloudProviderError.deletionIncomplete)
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"])
		}

		@Test
		func deleteFolderWithFailedMetadataReadAtDirectoryPathKeepsReference() async throws {
			let provider = makeNestedProvider(subdirectories: [:], files: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB": Data()])
			provider.metadataHook = { _ in
				throw CloudProviderError.unauthorized
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.unauthorized) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == [])
		}

		/// Only a first page tells a file at the path from a directory, so a later page's `itemTypeMismatch` neither deletes anything nor lets the `.c9r` be deleted.
		@Test
		func deleteFolderWithItemTypeMismatchOnLaterPageKeepsReference() async throws {
			let provider = makeNestedProvider(subdirectories: [:], files: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/a.c9r": Data(), "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/b.c9r": Data()], maxPageSize: 1)
			provider.listingHook = { cloudPath, pageToken in
				if cloudPath.path == "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", pageToken != nil {
					throw CloudProviderError.itemTypeMismatch
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(!provider.calls.contains("fetchItemMetadata"))
			#expect(provider.deleted == [])
		}

		@Test(arguments: Stacking.allCases)
		func moveFolderWithMoveCompletedUpdatesCacheAndRethrows(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try decorator.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir1-id".utf8))
			provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2")) }
			#expect(try Data("dir1-id".utf8) == decorator.dirIdCache.get(CloudPath("/Directory 2")))
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		/// A move that failed otherwise left no usable target, so the cache must not map one.
		@Test(arguments: Stacking.allCases)
		func moveFolderWithOtherMoveErrorSkipsCacheUpdate(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try decorator.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir1-id".utf8))
			provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.itemAlreadyExists)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2")) }
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 2")) == nil)
			#expect(try Data("dir1-id".utf8) == decorator.dirIdCache.get(CloudPath("/Directory 1")))
		}

		@Test(arguments: Stacking.allCases)
		func testMoveFile(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/Directory 1/File 2"))
			#expect(provider.moved.count == 1)
			#expect(provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"] == "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file2.c9r")
		}

		@Test(arguments: Stacking.allCases)
		func throwsCancellationErrorInCancelledTask(stacking: Stacking) async throws {
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			await assertThrowsCancellationErrorInCancelledTask(decorator)
			#expect(provider.calls == [])
		}

		// MARK: - Internal

		/// Returns a provider that holds `Directory 1`, the given subdirectory references (by path below `pathToVault/d` and dir ID, replacing a default one) and the given folders and files. The directories of `dir1-id` to `dir4-id` exist.
		func makeNestedProvider(subdirectories: [String: String], folders: Set<String> = [], files: [String: Data] = [:], maxPageSize: Int = .max) -> CloudProviderMock {
			let directories = ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"]
			let references = ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r": "dir1-id"].merging(subdirectories) { $1 }
			let folders = folders.union(["pathToVault", "pathToVault/d"] + (directories + references.keys).map { "pathToVault/d/\($0)" })
			let dirFiles = Dictionary(uniqueKeysWithValues: references.map { ("pathToVault/d/\($0.key)/dir.c9r", Data($0.value.utf8)) })
			return CloudProviderMock(folders: folders, files: dirFiles.merging(files) { $1 }, maxPageSize: maxPageSize)
		}

		/// Returns a provider whose `Directory 1` is a `.c9r` holding the given files and folders by name.
		func makeBrokenFolderProvider(files: [String] = [], folders: [String] = [], maxPageSize: Int = .max) -> CloudProviderMock {
			let c9rPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"
			let baseFolders: Set = ["pathToVault", "pathToVault/d", "pathToVault/d/00", "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", c9rPath]
			return CloudProviderMock(folders: baseFolders.union(folders.map { "\(c9rPath)/\($0)" }), files: Dictionary(uniqueKeysWithValues: files.map { ("\(c9rPath)/\($0)", Data()) }), maxPageSize: maxPageSize)
		}

		func assertDeleted(_ temporaryURLs: [URL], sourceLocation: SourceLocation = #_sourceLocation) {
			#expect(!temporaryURLs.isEmpty, sourceLocation: sourceLocation)
			for temporaryURL in temporaryURLs {
				#expect(!FileManager.default.fileExists(atPath: temporaryURL.path), sourceLocation: sourceLocation)
			}
		}
	}
}
