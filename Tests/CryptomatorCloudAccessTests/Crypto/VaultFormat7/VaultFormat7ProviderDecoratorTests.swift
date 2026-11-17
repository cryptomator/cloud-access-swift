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
				case "pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD": throw CloudProviderError.unauthorized
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

		/// The `itemTypeMismatch` of the directory of `Directory 2` must not reach `deleteFolder`'s catch that deletes the `.c9r` of a broken folder.
		@Test(arguments: zip([CloudProviderError.unauthorized, .itemTypeMismatch], [CloudProviderError.unauthorized, .itemNotFound]))
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
					throw CloudProviderError.unauthorized
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.unauthorized) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == ["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"])
		}

		/// The failure of `Directory 2` on the first page doesn't stop the delete, and the unlistable `Directory 3` on the second page takes precedence over it.
		@Test
		func deleteFolderWithFailedSubdirectoryThenUnlistableSubdirectoryOnLaterPageThrowsItemNotFound() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir3.c9r": "dir3-id"], maxPageSize: 1)
			provider.listingHook = { cloudPath, _ in
				switch cloudPath.path {
				case "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC": throw CloudProviderError.unauthorized
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
				case ("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", _): throw CloudProviderError.unauthorized
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

		/// Returns a provider whose `Directory 1` holds the given subdirectory references, by path below `pathToVault/d` and dir ID. The directories of `dir1-id` to `dir4-id` exist.
		func makeNestedProvider(subdirectories: [String: String], files: [String: Data] = [:], maxPageSize: Int = .max) -> CloudProviderMock {
			let directories = ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"]
			let references = ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r": "dir1-id"].merging(subdirectories) { $1 }
			let folders = Set(["pathToVault", "pathToVault/d"] + (directories + references.keys).map { "pathToVault/d/\($0)" })
			let dirFiles = Dictionary(uniqueKeysWithValues: references.map { ("pathToVault/d/\($0.key)/dir.c9r", Data($0.value.utf8)) })
			return CloudProviderMock(folders: folders, files: dirFiles.merging(files) { $1 }, maxPageSize: maxPageSize)
		}

		func assertDeleted(_ temporaryURLs: [URL], sourceLocation: SourceLocation = #_sourceLocation) {
			#expect(!temporaryURLs.isEmpty, sourceLocation: sourceLocation)
			for temporaryURL in temporaryURLs {
				#expect(!FileManager.default.fileExists(atPath: temporaryURL.path), sourceLocation: sourceLocation)
			}
		}
	}
}
