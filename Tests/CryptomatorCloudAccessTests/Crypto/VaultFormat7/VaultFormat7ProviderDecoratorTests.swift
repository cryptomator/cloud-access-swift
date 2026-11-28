//
//  VaultFormat7ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessTestSupport
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
		/// The `.c9s` of `File 4 (Long)` in the vault mock.
		static let shortenedFileC9SPath = "\(VaultTestFormat.rootDirectory)/\(VaultTestFormat.file4C9SName)"

		init() throws {
			self.tmpDirURL = try makeTemporaryDirectory()
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		/// The `.c9r` suffix forms one `Character` with a prepended mark before it, but the listing still strips it.
		@Test
		func fetchItemListStripsSuffixInCombinedCharacter() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let provider = CloudProviderMock(folders: VaultTestFormat.rootDirectoryAncestors.union([dirPath]), files: ["\(dirPath)/x\u{600}.c9r": Data()])
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
			let localURL = try makeLocalFile(in: tmpDirURL, content: "cleartext3")
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await decorator.uploadFile(from: localURL, to: CloudPath("/File 3"), replaceExisting: false) }
			#expect(provider.createdFiles == [:])
		}

		/// A folder's `.c9r` holds the name, which the provider refuses to replace with a file.
		@Test
		func uploadFileOverFolderWithReplaceExistingThrowsItemAlreadyExists() async throws {
			let fixture = try VaultFormat7Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			let localURL = try makeLocalFile(in: tmpDirURL, content: "cleartext3")
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
			let localURL = try makeLocalFile(in: tmpDirURL, content: "cleartext3")
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
			let folders = VaultTestFormat.rootDirectoryAncestors.union([
				VaultTestFormat.rootDirectory,
				"\(VaultTestFormat.rootDirectory)/dir1.c9r",
				VaultTestFormat.directory1,
				"\(VaultTestFormat.directory1)/dir2.c9r",
				VaultTestFormat.directory2
			])
			let files = [
				"\(VaultTestFormat.directory1)/dir2.c9r/dir.c9r": Data("dir2-id".utf8),
				"\(VaultTestFormat.directory1)/file3.c9r": Data("ciphertext3".utf8)
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
			let folderC9SPath = "\(VaultTestFormat.directory1)/folder.c9s"
			let fileC9SPath = "\(VaultTestFormat.directory1)/file.c9s"
			let provider = makeNestedProvider(subdirectories: ["\(VaultTestFormat.directory1)/folder.c9s": "dir2-id"], folders: [fileC9SPath], files: ["\(folderC9SPath)/name.c9s": Data(), "\(fileC9SPath)/contents.c9r": Data(), "\(fileC9SPath)/name.c9s": Data()])
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
			#expect(provider.deleted == [VaultTestFormat.directory2, VaultTestFormat.directory1, "\(VaultTestFormat.rootDirectory)/dir1.c9r"])
			#expect(downloadedNameFiles.withLock { $0 } == [])
		}

		/// The `.c9r` and `.c9s` suffixes form one `Character` with a prepended mark before them, but they still mark a Cryptomator item.
		@Test
		func deleteFolderFollowsDirFilesOfItemsWhoseSuffixIsInCombinedCharacter() async throws {
			let provider = makeNestedProvider(subdirectories: ["\(VaultTestFormat.directory1)/dir2\u{600}.c9r": "dir2-id", "\(VaultTestFormat.directory1)/dir3\u{600}.c9s": "dir3-id"])
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted.sorted() == ["\(VaultTestFormat.rootDirectory)/dir1.c9r", VaultTestFormat.directory1, VaultTestFormat.directory2, VaultTestFormat.directory3])
		}

		/// Only a `.c9r` or `.c9s` folder is a Cryptomator item, so the directory of the `dir.c9r` in another folder isn't deleted.
		@Test
		func deleteFolderIgnoresDirFileOfOtherFolder() async throws {
			let provider = makeNestedProvider(subdirectories: ["\(VaultTestFormat.directory1)/backup": "dir2-id"])
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == [VaultTestFormat.directory1, "\(VaultTestFormat.rootDirectory)/dir1.c9r"])
		}

		@Test
		func deleteFolderDoesNotReadAliasDirFile() async throws {
			let subfolderPath = "\(VaultTestFormat.directory1)/sub.c9r"
			let provider = makeNestedProvider(subdirectories: ["\(VaultTestFormat.directory1)/sub.c9r": "dir2-id"], aliases: ["\(subfolderPath)/dir.c9r"])
			let (listedFolders, transferredFiles) = provider.recordingListingsAndTransfers()
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(listedFolders.withLock { $0 } == [VaultTestFormat.directory1, subfolderPath])
			#expect(transferredFiles.withLock { $0 } == ["\(VaultTestFormat.rootDirectory)/dir1.c9r/dir.c9r"])
			#expect(provider.deleted == [VaultTestFormat.directory1, "\(VaultTestFormat.rootDirectory)/dir1.c9r"])
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
			let c9sPath = "\(VaultTestFormat.rootDirectory)/\(VaultTestFormat.dir3C9SName)"
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
			let provider = makeNestedProvider(subdirectories: [:], folders: ["\(VaultTestFormat.directory1)/sub.c9r", "\(VaultTestFormat.directory1)/sub.c9r/dir.c9r"])
			let decorator = try VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == [VaultTestFormat.directory1, "\(VaultTestFormat.rootDirectory)/dir1.c9r"])
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

		/// Only a `dir.c9r` file holds a dir ID, so a `.c9r` without one is deleted without a walk. A `contents.c9r` holds a file only in a `.c9s`.
		@Test(arguments: zip([["symlink.c9r"], [], ["contents.c9r"]], [[], ["dir.c9r"], []]))
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

		// MARK: - Parent Files

		/// A provider that addresses items by cached IDs reports a `dir.c9r` that another client replaced as missing, so the listed `dir.c9r`, also an alias, shows that the `.c9s` isn't a file.
		@Test(arguments: [false, true], [false, true])
		func readBelowC9SWithUnreadableDirFileThrowsItemTypeMismatch(isAlias: Bool, reversesPages: Bool) async throws {
			let provider = makeShortenedFileProvider(files: ["contents.c9r", "dir.c9r"], aliases: isAlias ? ["dir.c9r"] : [], reversesPages: reversesPages)
			provider.transferHook = { cloudPath, _ in
				if cloudPath.lastPathComponent == "dir.c9r" {
					throw CloudProviderError.itemNotFound
				}
			}
			try await expectItemTypeMismatch(below: CloudPath("/File 4 (Long)"), of: makeShorteningDecorator(over: provider))
		}

		/// Only a `.c9s` whose item files are all `contents.c9r` files holds a file. Where it also holds a `contents.c9r` file, the other item file lies on a later page, so the first page can't settle it. The download of a `dir.c9r` fails as through a stale cached ID, because the provider would refuse a download of a `dir.c9r` folder before the classification.
		@Test(arguments: zip([["symlink.c9r"], [], ["contents.c9r", "symlink.c9r"], ["contents.c9r"]], [[], ["contents.c9r"], [], ["dir.c9r"]]))
		func readBelowC9SHoldingNotOnlyFileThrowsItemTypeMismatch(files: [String], folders: [String]) async throws {
			let provider = makeShortenedFileProvider(files: files, folders: folders, maxPageSize: 1)
			provider.downloadHook = { cloudPath in
				if cloudPath.lastPathComponent == "dir.c9r" {
					throw CloudProviderError.itemNotFound
				}
			}
			try await expectItemTypeMismatch(below: CloudPath("/File 4 (Long)"), of: makeShorteningDecorator(over: provider))
		}

		/// The listing of the `.c9s` ends before it shows whether the `dir.c9r` on its second page exists.
		@Test
		func readBelowC9SWhoseLaterPageIsMissingThrowsItemTypeMismatch() async throws {
			let provider = makeShortenedFileProvider(files: ["contents.c9r", "dir.c9r"], maxPageSize: 1)
			provider.transferHook = { cloudPath, _ in
				if cloudPath.lastPathComponent == "dir.c9r" {
					throw CloudProviderError.itemNotFound
				}
			}
			let laterPageRequested = TestSignal("later page of the .c9s requested")
			let c9sPath = Self.shortenedFileC9SPath
			provider.listingHook = { cloudPath, pageToken in
				if cloudPath.path == c9sPath, pageToken != nil {
					laterPageRequested.fulfill()
					throw CloudProviderError.itemNotFound
				}
			}
			let decorator = try makeShorteningDecorator(over: provider)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await decorator.fetchItemMetadata(at: CloudPath("/File 4 (Long)/File 3")) }
			#expect(laterPageRequested.fulfillmentCount == 1)
		}

		/// A provider that addresses items by cached IDs reports a `dir.c9r` that another client replaced as missing, while the `.c9r` is still a folder.
		@Test
		func readBelowFolderWithUnreadableDirFileThrowsItemTypeMismatch() async throws {
			let provider = CloudProviderMock.vaultFormat7()
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == "\(VaultTestFormat.rootDirectory)/dir1.c9r/dir.c9r" {
					throw CloudProviderError.itemNotFound
				}
			}
			try await expectItemTypeMismatch(below: CloudPath("/Directory 1"), of: VaultFormat7ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor))
		}

		/// A stale cached ID can reach another item, which reports its own name.
		@Test(arguments: zip(["/File 1", "/File 4 (Long)"], ["\(VaultTestFormat.rootDirectory)/file1.c9r", VaultFormat7ProviderDecoratorTests.shortenedFileC9SPath]))
		func readBelowItemReportingAnotherNameThrowsItemTypeMismatch(cleartextPath: String, physicalPath: String) async throws {
			let provider = CloudProviderMock.vaultFormat7()
			provider.metadataOverride = { cloudPath in
				guard cloudPath.path == physicalPath else {
					return nil
				}
				let itemType: CloudItemType = physicalPath.hasUTF8Suffix(".c9s") ? .folder : .file
				return CloudItemMetadata(name: "renamed", cloudPath: cloudPath, itemType: itemType, lastModifiedDate: nil, size: nil)
			}
			try await expectItemTypeMismatch(below: CloudPath(cleartextPath), of: makeShorteningDecorator(over: provider))
		}

		/// S3 reports an object at the `.c9s` key as a file while the `.c9s` prefix holds items, and a LocalFS or Google Drive `.c9s` can read as a symlink or of unknown type, so the listing decides. A folder delete refuses the shortened file, because deleting its `.c9s` would delete the file. A path below it names no item.
		@Test(arguments: [CloudItemType.file, .symlink, .unknown])
		func deleteFolderOfShortenedFileWhoseC9SReadsAsNoFolderThrowsItemTypeMismatch(itemType: CloudItemType) async throws {
			let provider = CloudProviderMock.vaultFormat7()
			provider.metadataOverride = CloudProviderMock.reading([itemType], at: Self.shortenedFileC9SPath)
			let decorator = try makeShorteningDecorator(over: provider)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await decorator.deleteFolder(at: CloudPath("/File 4 (Long)")) }
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.fetchItemMetadata(at: CloudPath("/File 4 (Long)/File 3")) }
			#expect(provider.deleted == [])
		}

		/// A `.c9s` that reads as a file isn't confirmed as one if its listing shows another item file.
		@Test
		func readBelowC9SReadingAsFileHoldingSymlinkThrowsItemTypeMismatch() async throws {
			let provider = makeShortenedFileProvider(files: ["symlink.c9r"])
			provider.metadataOverride = CloudProviderMock.reading([.file], at: Self.shortenedFileC9SPath)
			try await expectItemTypeMismatch(below: CloudPath("/File 4 (Long)"), of: makeShorteningDecorator(over: provider))
		}

		/// Another item file than a `contents.c9r` file on the first page doesn't end the listing, so the failure of a later page reaches the caller.
		@Test
		func readBelowC9SWithOtherItemFileThrowsLaterPageFailure() async throws {
			let provider = makeShortenedFileProvider(folders: ["contents.c9r"], maxPageSize: 1)
			let c9sPath = Self.shortenedFileC9SPath
			provider.listingHook = { cloudPath, pageToken in
				if cloudPath.path == c9sPath, pageToken != nil {
					throw CloudProviderError.noInternetConnection
				}
			}
			let decorator = try makeShorteningDecorator(over: provider)
			await #expect(throws: CloudProviderError.noInternetConnection) { try await decorator.fetchItemMetadata(at: CloudPath("/File 4 (Long)/File 3")) }
		}

		/// A shortened file whose `.c9s` can't be confirmed is refused by the delete's lookup of its `contents.c9r`: a stale cached ID reaches the `.c9s` under another name after another client renamed it, a later page of the confirming listing fails, or every listing of the `.c9s` fails, as a listing that leaves the file out would.
		@Test(arguments: ["renamed", "laterPageFailsOnce", "listingFails"])
		func deleteFolderOfUnconfirmedShortenedFileThrowsItemTypeMismatch(unconfirmedBy cause: String) async throws {
			let provider = makeShortenedFileProvider(files: ["contents.c9r"], maxPageSize: cause == "laterPageFailsOnce" ? 1 : .max)
			let c9sPath = Self.shortenedFileC9SPath
			let failedListings = OSAllocatedUnfairLock(initialState: 0)
			if cause == "renamed" {
				provider.metadataOverride = { cloudPath in
					return cloudPath.path == c9sPath ? CloudItemMetadata(name: "renamed.c9s", cloudPath: cloudPath, itemType: .folder, lastModifiedDate: nil, size: nil) : nil
				}
			} else {
				provider.listingHook = { cloudPath, pageToken in
					guard cloudPath.path == c9sPath, cause == "listingFails" || pageToken != nil else {
						return
					}
					let isFirstFailure = failedListings.withLock { count in
						defer { count += 1 }
						return count == 0
					}
					if cause == "listingFails" || isFirstFailure {
						throw CloudProviderError.itemNotFound
					}
				}
			}
			let decorator = try makeShorteningDecorator(over: provider)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await decorator.deleteFolder(at: CloudPath("/File 4 (Long)")) }
			#expect(provider.deleted == [])
			#expect((failedListings.withLock { $0 } > 0) == (cause != "renamed"))
		}

		/// The delete's lookup of the `contents.c9r` fails, so it can't tell whether the `.c9s` holds a file and deletes nothing.
		@Test
		func deleteFolderOfShortenedFileWhoseContentsLookupFailsThrowsIt() async throws {
			let provider = makeShortenedFileProvider(files: ["contents.c9r"])
			let c9sPath = Self.shortenedFileC9SPath
			provider.listingHook = { cloudPath, _ in
				if cloudPath.path == c9sPath {
					throw CloudProviderError.itemNotFound
				}
			}
			provider.metadataHook = { cloudPath in
				if cloudPath.path == "\(c9sPath)/contents.c9r" {
					throw CloudProviderError.quotaInsufficient
				}
			}
			let decorator = try makeShorteningDecorator(over: provider)
			await #expect(throws: CloudProviderError.quotaInsufficient) { try await decorator.deleteFolder(at: CloudPath("/File 4 (Long)")) }
			#expect(provider.deleted == [])
		}

		/// The shortening decorator reports a file at a `.c9s` name as missing, so a path below it names no item either.
		@Test
		func readBelowFileAtC9SNameThrowsItemNotFound() async throws {
			let c9sPath = Self.shortenedFileC9SPath
			let fixture = CloudProviderMock.vaultFormat7()
			let files = fixture.files.filter { !$0.key.hasUTF8Prefix("\(c9sPath)/") }.merging([c9sPath: Data()]) { $1 }
			let provider = CloudProviderMock(folders: fixture.folders.subtracting([c9sPath]), files: files)
			let decorator = try makeShorteningDecorator(over: provider)
			let belowPath = CloudPath("/File 4 (Long)/File 3")
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.fetchItemMetadata(at: belowPath) }
			let exists = try await decorator.checkForItemExistence(at: belowPath)
			#expect(!exists)
		}

		// MARK: - Internal

		/// Expects that a read and a folder delete below the item at the path keep `itemTypeMismatch`, so that `deleteFolderIfExisting` doesn't take the path for gone.
		func expectItemTypeMismatch(below cloudPath: CloudPath, of decorator: VaultFormat7ProviderDecorator, sourceLocation: SourceLocation = #_sourceLocation) async {
			let belowPath = cloudPath.appendingPathComponent("File 3")
			await #expect(throws: CloudProviderError.itemTypeMismatch, sourceLocation: sourceLocation) { try await decorator.fetchItemMetadata(at: belowPath) }
			await #expect(throws: CloudProviderError.itemTypeMismatch, sourceLocation: sourceLocation) { try await decorator.deleteFolderIfExisting(at: belowPath) }
		}

		/// Returns a vault mock whose `.c9s` of `File 4 (Long)` holds its name file and the given files and folders by name instead of its `contents.c9r`. A listing marks the items of `aliases` as aliases.
		func makeShortenedFileProvider(files: [String] = [], folders: [String] = [], maxPageSize: Int = .max, aliases: [String] = [], reversesPages: Bool = false) -> CloudProviderMock {
			let c9sPath = Self.shortenedFileC9SPath
			let fixture = CloudProviderMock.vaultFormat7()
			let fixtureFiles = fixture.files.filter { $0.key != "\(c9sPath)/contents.c9r" }
			return CloudProviderMock(folders: fixture.folders.union(folders.map { "\(c9sPath)/\($0)" }), files: fixtureFiles.merging(files.map { ("\(c9sPath)/\($0)", Data()) }) { $1 }, maxPageSize: maxPageSize, aliases: Set(aliases.map { "\(c9sPath)/\($0)" }), reversesPages: reversesPages)
		}

		func makeShorteningDecorator(over provider: CloudProvider) throws -> VaultFormat7ProviderDecorator {
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			return try VaultFormat7ProviderDecorator(shortening: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
		}

		/// Returns a provider that holds `Directory 1`, the given subdirectory references (by full path and dir ID, replacing a default one) and the given folders and files. The directories of `dir1-id` to `dir4-id` exist. A listing marks the items at the full paths of `aliases` as aliases, and a download those of `aliasedDownloads`.
		func makeNestedProvider(subdirectories: [String: String], folders: Set<String> = [], files: [String: Data] = [:], maxPageSize: Int = .max, aliases: Set<String> = [], aliasedDownloads: Set<String> = []) -> CloudProviderMock {
			let references = ["\(VaultTestFormat.rootDirectory)/dir1.c9r": "dir1-id"].merging(subdirectories) { $1 }
			let folders = folders.union(["pathToVault", "pathToVault/d"] + VaultTestFormat.nestedDirectories.map { "pathToVault/d/\($0)" } + references.keys)
			let dirFiles = Dictionary(uniqueKeysWithValues: references.map { ("\($0.key)/dir.c9r", Data($0.value.utf8)) })
			return CloudProviderMock(folders: folders, files: dirFiles.merging(files) { $1 }, maxPageSize: maxPageSize, aliases: aliases, aliasedDownloads: aliasedDownloads)
		}

		/// Returns a provider whose `Directory 1` is a `.c9r` holding the given files and folders by name.
		func makeBrokenFolderProvider(files: [String] = [], folders: [String] = [], maxPageSize: Int = .max) -> CloudProviderMock {
			let c9rPath = "\(VaultTestFormat.rootDirectory)/dir1.c9r"
			let baseFolders = VaultTestFormat.rootDirectoryAncestors.union([VaultTestFormat.rootDirectory, c9rPath])
			return CloudProviderMock(folders: baseFolders.union(folders.map { "\(c9rPath)/\($0)" }), files: Dictionary(uniqueKeysWithValues: files.map { ("\(c9rPath)/\($0)", Data()) }), maxPageSize: maxPageSize)
		}
	}
}
