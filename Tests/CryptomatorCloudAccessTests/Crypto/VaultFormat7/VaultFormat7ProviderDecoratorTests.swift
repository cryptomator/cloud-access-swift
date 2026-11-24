//
//  VaultFormat7ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

/// The decorator of a test, stacked onto a fresh vault mock directly or through the shortening decorator.
struct VaultFormat7Fixture {
	let provider = CloudProviderMock.vaultFormat7()
	let shorteningDecorator: VaultFormat7ShorteningProviderDecorator?
	let decorator: VaultFormat7ProviderDecorator

	init(stacking: Stacking, vaultPath: CloudPath, cryptor: CryptorMock) throws {
		switch stacking {
		case .plain:
			self.shorteningDecorator = nil
			self.decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
		case .shortening:
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			self.shorteningDecorator = shorteningDecorator
			self.decorator = try VaultFormat7ProviderDecorator(shortening: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
		}
	}
}

extension UnitTests {
	final class VaultFormat7ProviderDecoratorTests {
		let vaultPath = CloudPath("pathToVault")
		let cryptor = CryptorMock.vaultFormat7()
		let tmpDirURL: URL

		init() throws {
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		/// The `.c9r` suffix forms one `Character` with a prepended mark before it, but the listing still strips it.
		@Test
		func fetchItemListStripsSuffixInCombinedCharacter() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: ["\(dirPath)/x\u{600}.c9r": Data()])
			let cryptor = CryptorMock(dirIds: ["": VaultTestFormat.encryptedRootDirId], fileNames: ["x\u{600}": "File X"], contents: [:])
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect([CloudPath("/File X")] == itemList.items.map(\.cloudPath))
		}

		@Test
		func fetchItemListListsCreatedFolder() async throws {
			let fixture = try VaultFormat7Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			try await fixture.decorator.createFolder(at: CloudPath("/Directory 2"))
			let itemList = try await fixture.decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect(itemList.items.map(\.name).sorted() == ["Directory 1", "Directory 2", "File 1", "File 2"])
		}

		/// The root's directory is missing or a file, so the provider refuses the upload into it.
		@Test(arguments: [false, true])
		func uploadFileWithoutRootDirectoryThrowsParentFolderDoesNotExist(rootDirectoryIsFile: Bool) async throws {
			let provider = rootDirectoryIsFile ? CloudProviderMock(folders: [], files: [VaultTestFormat.rootDirectory: Data()]) : CloudProviderMock(folders: [vaultPath.path], files: [:])
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			let localURL = try makeLocalFile()
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await decorator.uploadFile(from: localURL, to: CloudPath("/File 3"), replaceExisting: false) }
			#expect(provider.createdFiles == [:])
		}

		/// A folder's `.c9r` holds the name, which the provider refuses to replace with a file.
		@Test
		func uploadFileOverFolderWithReplaceExistingThrowsItemAlreadyExists() async throws {
			let fixture = try VaultFormat7Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			let localURL = try makeLocalFile()
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await fixture.decorator.uploadFile(from: localURL, to: CloudPath("/Directory 1"), replaceExisting: true) }
			#expect(fixture.provider.createdFiles == [:])
		}

		/// Another client creates a folder at the name while the upload transfers.
		@Test
		func uploadFileWhoseTargetAppearsDuringTransferThrowsItemAlreadyExists() async throws {
			let fixture = try VaultFormat7Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			let provider = fixture.provider
			provider.transferHook = { _, _ in
				try await provider.createFolder(at: CloudPath("\(VaultTestFormat.rootDirectory)/file3.c9r"))
			}
			let localURL = try makeLocalFile()
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await fixture.decorator.uploadFile(from: localURL, to: CloudPath("/File 3"), replaceExisting: true) }
			#expect(provider.createdFiles == [:])
		}

		@Test
		func moveFileOntoExistingFileThrowsItemAlreadyExists() async throws {
			let fixture = try VaultFormat7Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await fixture.decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/File 2")) }
			#expect(fixture.provider.moved == [:])
		}

		@Test
		func moveFileOfMissingFileThrowsItemNotFound() async throws {
			let fixture = try VaultFormat7Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await fixture.decorator.moveFile(from: CloudPath("/File 3"), to: CloudPath("/Directory 1/File 1")) }
			#expect(fixture.provider.moved == [:])
		}

		/// A folder's `.c9r` holds the name, which the provider refuses to move as a file.
		@Test
		func moveFileOfFolderThrowsItemTypeMismatch() async throws {
			let fixture = try VaultFormat7Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await fixture.decorator.moveFile(from: CloudPath("/Directory 1"), to: CloudPath("/File 3")) }
			#expect(fixture.provider.moved == [:])
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
				VaultTestFormat.rootDirectory,
				"\(VaultTestFormat.rootDirectory)/dir1.c9r",
				"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
				"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r",
				"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
			]
			let files = [
				"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r/dir.c9r": Data("dir2-id".utf8),
				"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r": Data("ciphertext3".utf8)
			]
			let provider = CloudProviderMock(folders: folders, files: files)
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains("\(VaultTestFormat.rootDirectory)/dir1.c9r"))
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
			let decorator = try VaultFormat7ProviderDecorator(shortening: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "\(VaultTestFormat.rootDirectory)/dir1.c9r"])
			#expect(downloadedNameFiles.withLock { $0 } == [])
		}

		/// The `.c9r` and `.c9s` suffixes form one `Character` with a prepended mark before them, but they still mark a Cryptomator item.
		@Test
		func deleteFolderFollowsDirFilesOfItemsWhoseSuffixIsInCombinedCharacter() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2\u{600}.c9r": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir3\u{600}.c9s": "dir3-id"])
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted.sorted() == ["\(VaultTestFormat.rootDirectory)/dir1.c9r", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"])
		}

		/// Only a `.c9r` or `.c9s` folder is a Cryptomator item, so the directory of the `dir.c9r` in another folder isn't deleted.
		@Test
		func deleteFolderIgnoresDirFileOfOtherFolder() async throws {
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/backup": "dir2-id"])
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "\(VaultTestFormat.rootDirectory)/dir1.c9r"])
		}

		@Test
		func deleteFolderDoesNotReadAliasDirFile() async throws {
			let subfolderPath = "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/sub.c9r"
			let provider = makeNestedProvider(subdirectories: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/sub.c9r": "dir2-id"], aliases: ["\(subfolderPath)/dir.c9r"])
			let (listedFolders, transferredFiles) = provider.recordingListingsAndTransfers()
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(listedFolders.withLock { $0 } == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", subfolderPath])
			#expect(transferredFiles.withLock { $0 } == ["\(VaultTestFormat.rootDirectory)/dir1.c9r/dir.c9r"])
			#expect(provider.deleted == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "\(VaultTestFormat.rootDirectory)/dir1.c9r"])
		}

		/// A provider that addresses items by cached IDs reports a `dir.c9r` that another client replaced as missing, while the folder still lists it.
		@Test
		func deleteFolderWithUnreadableListedDirFileKeepsReference() async throws {
			let provider = CloudProviderMock.vaultFormat7()
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == "\(VaultTestFormat.rootDirectory)/dir1.c9r/dir.c9r" {
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
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
				if cloudPath.path == "\(VaultTestFormat.rootDirectory)/dir1.c9r" {
					withUnsafeCurrentTask { $0?.cancel() }
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			let deletion = Task {
				try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: deletion) }
			#expect(provider.deleted == [])
		}

		/// The `.c9s` of a long name is listed physically, so its unreadable `dir.c9r` keeps the reference, and a `.c9s` that a partial delete left with only `name.c9s` is deleted.
		@Test(arguments: [true, false])
		func deleteFolderWithLongNameWithoutReadableDirFile(holdsDirFile: Bool) async throws {
			let c9sPath = "\(VaultTestFormat.rootDirectory)/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"
			let fixture = CloudProviderMock.vaultFormat7()
			let provider = CloudProviderMock(folders: fixture.folders, files: fixture.files.filter { holdsDirFile || $0.key != "\(c9sPath)/dir.c9r" })
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == "\(c9sPath)/dir.c9r" {
					throw CloudProviderError.itemNotFound
				}
			}
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let decorator = try VaultFormat7ProviderDecorator(shortening: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
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
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "\(VaultTestFormat.rootDirectory)/dir1.c9r"])
		}

		/// A `.c9r` without a readable `dir.c9r` is listed before it is deleted, to tell whether it holds one.
		@Test
		func deleteFolderWithoutDirFileRequests() async throws {
			let c9rPath = "\(VaultTestFormat.rootDirectory)/dir1.c9r"
			let provider = makeBrokenFolderProvider(files: ["symlink.c9r"])
			let requests = provider.recordingRequests()
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemMetadata", "fetchItemList", "deleteFolder"], metadataReads: [c9rPath], listings: [c9rPath], deleted: [c9rPath]))
		}

		/// Only a `dir.c9r` file holds a dir ID, so a `.c9r` without one is deleted without a walk.
		@Test(arguments: zip([["symlink.c9r"], []], [[], ["dir.c9r"]]))
		func deleteFolderWithoutDirFileDeletesReference(files: [String], folders: [String]) async throws {
			let provider = makeBrokenFolderProvider(files: files, folders: folders)
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["\(VaultTestFormat.rootDirectory)/dir1.c9r"])
		}

		/// The `dir.c9r` lies on the second page of the `.c9r`, whose listing may also fail.
		@Test(arguments: [false, true])
		func deleteFolderWithUnreadableDirFileOnLaterPageKeepsReference(laterPageFails: Bool) async throws {
			let provider = makeBrokenFolderProvider(files: ["aaa", "dir.c9r"], maxPageSize: 1)
			provider.transferHook = { _, _ in
				throw CloudProviderError.itemNotFound
			}
			provider.listingHook = { cloudPath, pageToken in
				if laterPageFails, cloudPath.path == "\(VaultTestFormat.rootDirectory)/dir1.c9r", pageToken != nil {
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
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
				if cloudPath.path == "\(VaultTestFormat.rootDirectory)/dir1.c9r", pageToken != nil {
					laterPageRequested.fulfill()
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(laterPageRequested.fulfillmentCount == 0)
			#expect(provider.deleted == [])
		}

		// MARK: - Internal

		func makeLocalFile() throws -> URL {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext3".write(to: localURL, atomically: true, encoding: .utf8)
			return localURL
		}

		/// Returns a provider that holds `Directory 1`, the given subdirectory references (by path below `pathToVault/d` and dir ID, replacing a default one) and the given folders and files. The directories of `dir1-id` to `dir4-id` exist. A listing marks the items at the full paths of `aliases` as aliases, and a download those of `aliasedDownloads`.
		func makeNestedProvider(subdirectories: [String: String], folders: Set<String> = [], files: [String: Data] = [:], maxPageSize: Int = .max, aliases: Set<String> = [], aliasedDownloads: Set<String> = []) -> CloudProviderMock {
			let references = ["\(VaultTestFormat.nestedDirectories[0])/dir1.c9r": "dir1-id"].merging(subdirectories) { $1 }
			let folders = folders.union(["pathToVault", "pathToVault/d"] + (VaultTestFormat.nestedDirectories + references.keys).map { "pathToVault/d/\($0)" })
			let dirFiles = Dictionary(uniqueKeysWithValues: references.map { ("pathToVault/d/\($0.key)/dir.c9r", Data($0.value.utf8)) })
			return CloudProviderMock(folders: folders, files: dirFiles.merging(files) { $1 }, maxPageSize: maxPageSize, aliases: aliases, aliasedDownloads: aliasedDownloads)
		}

		/// Returns a provider whose `Directory 1` is a `.c9r` holding the given files and folders by name.
		func makeBrokenFolderProvider(files: [String] = [], folders: [String] = [], maxPageSize: Int = .max) -> CloudProviderMock {
			let c9rPath = "\(VaultTestFormat.rootDirectory)/dir1.c9r"
			let baseFolders: Set = ["pathToVault", "pathToVault/d", "pathToVault/d/00", VaultTestFormat.rootDirectory, c9rPath]
			return CloudProviderMock(folders: baseFolders.union(folders.map { "\(c9rPath)/\($0)" }), files: Dictionary(uniqueKeysWithValues: files.map { ("\(c9rPath)/\($0)", Data()) }), maxPageSize: maxPageSize)
		}
	}
}
