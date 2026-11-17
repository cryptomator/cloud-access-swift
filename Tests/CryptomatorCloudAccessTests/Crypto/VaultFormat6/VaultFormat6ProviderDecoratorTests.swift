//
//  VaultFormat6ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

/// The decorator of a test, stacked onto a fresh vault mock directly or through the shortening decorator.
struct VaultFormat6Fixture {
	let provider = VaultFormat6CloudProviderMock()
	let shorteningDecorator: VaultFormat6ShorteningProviderDecorator?
	let decorator: VaultFormat6ProviderDecorator

	init(stacking: Stacking, vaultPath: CloudPath, cryptor: VaultFormat6CryptorMock) throws {
		switch stacking {
		case .plain:
			self.shorteningDecorator = nil
			self.decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		case .shortening:
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			self.shorteningDecorator = shorteningDecorator
			self.decorator = try VaultFormat6ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
		}
	}
}

extension UnitTests {
	final class VaultFormat6ProviderDecoratorTests {
		let vaultPath = CloudPath("pathToVault")
		let cryptor = VaultFormat6CryptorMock()
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
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			#expect(try ProcessTemporaryDirectory.shared.directoryURL().path == decorator.tmpDirURL.deletingLastPathComponent().path)
			if stacking == .shortening {
				let shorteningDecorator = try #require(fixture.shorteningDecorator)
				#expect(try ProcessTemporaryDirectory.shared.directoryURL().path == shorteningDecorator.tmpDirURL.deletingLastPathComponent().path)
			}
		}

		@Test(arguments: Stacking.allCases)
		func testFetchItemMetadata(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			let metadata = try await decorator.fetchItemMetadata(at: CloudPath("/Directory 1/File 3"))
			#expect(metadata.name == "File 3")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/Directory 1/File 3")
		}

		@Test(arguments: Stacking.allCases)
		func fetchItemListForRootDir(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
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
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1"), withPageToken: nil)
			#expect(itemList.items.count == 2)
			#expect(itemList.items.contains(where: { $0.name == "File 3" }))
			#expect(itemList.items.contains(where: { $0.name == "Directory 2" }))
		}

		@Test(arguments: Stacking.allCases)
		func fetchItemListForEmptyDir(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let decorator = fixture.decorator
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1/Directory 2"), withPageToken: nil)
			#expect(itemList.items.isEmpty)
		}

		@Test
		func fetchItemListSkipsNamesThatAreNoSinglePathComponent() async throws {
			let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: ["\(dirPath)/nested": Data(), "\(dirPath)/parent": Data(), "\(dirPath)/file1": Data()])
			let cryptor = CryptorMock(dirIds: ["": "00AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"], fileNames: ["nested": "a/b", "parent": "..", "file1": "File 1"], contents: [:])
			let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect([CloudPath("/File 1")] == itemList.items.map(\.cloudPath))
		}

		@Test(arguments: Stacking.allCases)
		func testDownloadFile(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
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
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
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
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
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
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
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
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
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
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }
			progressObserver.invalidate()
			#expect(progress.fractionCompleted < 0.9, "The decryption must not have finished")
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		@Test(arguments: Stacking.allCases)
		func testUploadFile(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
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
			#expect(Data("ciphertext1".utf8) == provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1"])
			#expect(metadata.name == "File 1")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/File 1")
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		@Test(arguments: Stacking.allCases)
		func uploadFileWithFailingTransfer(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
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
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
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
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }
			progressObserver.invalidate()
			// The encryption makes up the first 20 % of the progress.
			#expect(progress.fractionCompleted < 0.2, "The encryption must not have finished")
			#expect(!provider.calls.contains("uploadFile"))
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		@Test(arguments: Stacking.allCases)
		func testCreateFolder(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await decorator.createFolder(at: CloudPath("/Directory 1"))
			#expect(provider.createdFolders.count == 2)
			#expect(provider.createdFolders.contains("pathToVault/d/99"))
			#expect(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
			#expect(provider.createdFiles.count == 1)
			#expect(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"] != nil)
		}

		@Test(arguments: Stacking.allCases)
		func createFolderWithCancellationBeforeFirstRemoteChange(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			provider.metadataHook = { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let creation = Task {
				try await decorator.createFolder(at: CloudPath("/Directory 1"))
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: creation) }
			#expect(creation.isCancelled)
			#expect(provider.createdFolders.isEmpty)
			#expect(provider.createdFiles.isEmpty)
		}

		@Test(arguments: Stacking.allCases)
		func createFolderWithCancellationAfterFirstRemoteChange(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.createFolder(at: CloudPath("/Directory 1"))
			}
			#expect(provider.createdFolders.sorted() == ["pathToVault/d/99", "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"])
			#expect(Array(provider.createdFiles.keys) == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"])
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) != nil)
		}

		@Test(arguments: Stacking.allCases)
		func testDeleteFile(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await decorator.deleteFile(at: CloudPath("/Directory 1/File 3"))
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3"))
		}

		@Test(arguments: Stacking.allCases)
		func testDeleteFolder(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted.count == 3)
			#expect(provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
			#expect(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
			#expect(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"))
		}

		@Test(arguments: Stacking.allCases)
		func deleteFolderWithoutSubDirs(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2"))
			#expect(provider.deleted.count == 2)
			#expect(provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
			#expect(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2"))
		}

		@Test
		func deleteFolderWithPagedItemList() async throws {
			let fixture = VaultFormat6CloudProviderMock()
			let pagingProvider = VaultFormat6CloudProviderMock(folders: fixture.folders, files: fixture.files, maxPageSize: 1)
			let decorator = try VaultFormat6ProviderDecorator(delegate: pagingProvider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(pagingProvider.deleted.sorted() == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
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
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"))
		}

		@Test
		func deleteFolderWithBrokenFolder() async throws {
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
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"))
		}

		@Test(arguments: Stacking.allCases)
		func deleteFolderWithCancellationAfterFirstRemoteChange(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			}
			#expect(provider.deleted.sorted() == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		@Test(arguments: Stacking.allCases)
		func deleteFolderWithDeletionIncompleteKeepsDirFile(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"])
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(!provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"))
			#expect(try Data("dir1-id".utf8) == decorator.dirIdCache.get(CloudPath("/Directory 1")))
		}

		/// The refusal of `0dir4` keeps its ancestors although its parent's sibling `0dir3` is deleted.
		@Test
		func deleteFolderWithRefusedNestedSubdirectoryKeepsAncestors() async throws {
			let provider = makeNestedProvider(dirFiles: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir3": "dir3-id", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/0dir4": "dir4-id"])
			provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"])
			let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted.sorted() == ["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"])
		}

		/// A listing also fails with `itemNotFound` for a missing name file while the directory exists, which must neither count as deleted nor let the folder's dir file be deleted.
		@Test
		func deleteFolderWithItemNotFoundFromExistingSubdirectoryKeepsParent() async throws {
			let provider = makeNestedProvider(dirFiles: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": "dir2-id"])
			provider.listingHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" {
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == [])
		}

		@Test
		func deleteFolderWithFailedSubdirectoryAndDeletedSiblingKeepsParent() async throws {
			let provider = makeNestedProvider(dirFiles: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir3": "dir3-id"])
			provider.listingHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" {
					throw CloudProviderError.unauthorized
				}
			}
			let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.unauthorized) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == ["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"])
		}

		@Test
		func deleteFolderWithFailedDirFileDownloadAndDeletedSiblingKeepsParent() async throws {
			let provider = makeNestedProvider(dirFiles: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir3": "dir3-id"])
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2" {
					throw CloudProviderError.unauthorized
				}
			}
			let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.unauthorized) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == ["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"])
		}

		/// A refused delete leaves the dir file of a subdirectory whose directory is already gone, which a later delete counts as deleted.
		@Test
		func deleteFolderRetryAfterRefusedFinalDeleteFinishes() async throws {
			let fixture = VaultFormat6CloudProviderMock()
			let provider = VaultFormat6CloudProviderMock(folders: fixture.folders.subtracting(["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"]), files: fixture.files)
			let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted.sorted() == ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"])
		}

		@Test(arguments: Stacking.allCases)
		func moveFolderWithMoveCompletedUpdatesCacheAndRethrows(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try decorator.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir1-id".utf8))
			provider.afterMutationHook = CloudProviderMock.failing("moveFile", with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2")) }
			#expect(try Data("dir1-id".utf8) == decorator.dirIdCache.get(CloudPath("/Directory 2")))
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		@Test(arguments: Stacking.allCases)
		func testMoveFile(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/Directory 1/File 2"))
			#expect(provider.moved.count == 1)
			#expect(provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1"] == "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file2")
		}

		@Test(arguments: Stacking.allCases)
		func throwsCancellationErrorInCancelledTask(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			let decorator = fixture.decorator
			await assertThrowsCancellationErrorInCancelledTask(decorator)
			#expect(provider.calls == [])
		}

		// MARK: - Internal

		/// Returns a provider whose `Directory 1` holds the given dir files, by path below `pathToVault/d` and dir ID. The directories of `dir1-id` to `dir4-id` exist.
		func makeNestedProvider(dirFiles: [String: String]) -> CloudProviderMock {
			let directories = ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"]
			let folders = Set(["pathToVault", "pathToVault/d"] + directories.map { "pathToVault/d/\($0)" })
			let references = ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1": "dir1-id"].merging(dirFiles) { $1 }
			return CloudProviderMock(folders: folders, files: Dictionary(uniqueKeysWithValues: references.map { ("pathToVault/d/\($0.key)", Data($0.value.utf8)) }))
		}

		func assertDeleted(_ temporaryURLs: [URL], sourceLocation: SourceLocation = #_sourceLocation) {
			#expect(!temporaryURLs.isEmpty, sourceLocation: sourceLocation)
			for temporaryURL in temporaryURLs {
				#expect(!FileManager.default.fileExists(atPath: temporaryURL.path), sourceLocation: sourceLocation)
			}
		}
	}
}
