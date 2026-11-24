//
//  VaultFormat6ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

/// The decorator of a test, stacked onto a fresh vault mock directly or through the shortening decorator.
struct VaultFormat6Fixture {
	let provider = CloudProviderMock.vaultFormat6()
	let shorteningDecorator: VaultFormat6ShorteningProviderDecorator?
	let decorator: VaultFormat6ProviderDecorator

	init(stacking: Stacking, vaultPath: CloudPath, cryptor: CryptorMock) throws {
		switch stacking {
		case .plain:
			self.shorteningDecorator = nil
			self.decorator = try VaultFormat6ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
		case .shortening:
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			self.shorteningDecorator = shorteningDecorator
			self.decorator = try VaultFormat6ProviderDecorator(shortening: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
		}
	}
}

extension UnitTests {
	final class VaultFormat6ProviderDecoratorTests {
		let vaultPath = CloudPath("pathToVault")
		let cryptor = CryptorMock.vaultFormat6()
		let tmpDirURL: URL

		init() throws {
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		/// A folder's dir file carries the `0` prefix, so the metadata of a folder is read after that of a file of the name is missing.
		@Test(arguments: Stacking.allCases)
		func fetchItemMetadataOfFolderReadsDirFileAfterMissingFile(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let requests = fixture.provider.recordingRequests()
			let metadata = try await fixture.decorator.fetchItemMetadata(at: CloudPath("/Directory 1/Directory 2"))
			#expect(metadata.itemType == .folder)
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemMetadata", "fetchItemMetadata"], metadataReads: ["\(VaultTestFormat.directory1)/dir2", "\(VaultTestFormat.directory1)/0dir2"], transfers: ["\(VaultTestFormat.rootDirectory)/0dir1"]))
		}

		@Test(arguments: Stacking.allCases)
		func downloadFileOfFolderThrowsItemTypeMismatch(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let requests = fixture.provider.recordingRequests()
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await fixture.decorator.downloadFile(from: CloudPath("/Directory 1/Directory 2"), to: localURL) }
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "downloadFile", "fetchItemMetadata"], metadataReads: ["\(VaultTestFormat.directory1)/0dir2"], transfers: ["\(VaultTestFormat.rootDirectory)/0dir1"]))
		}

		@Test(arguments: Stacking.allCases)
		func uploadFileOverFolderThrowsItemAlreadyExists(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let requests = fixture.provider.recordingRequests()
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await fixture.decorator.uploadFile(from: localURL, to: CloudPath("/Directory 1/Directory 2"), replaceExisting: true) }
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemMetadata"], metadataReads: ["\(VaultTestFormat.directory1)/0dir2"], transfers: ["\(VaultTestFormat.rootDirectory)/0dir1"]))
		}

		@Test(arguments: Stacking.allCases)
		func createFolderOverFileThrowsItemAlreadyExists(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			let requests = fixture.provider.recordingRequests()
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await fixture.decorator.createFolder(at: CloudPath("/File 1")) }
			#expect(requests() == RecordedRequests(calls: ["fetchItemMetadata"], metadataReads: ["\(VaultTestFormat.rootDirectory)/file1"]))
		}

		/// The upload checks cancellation after reading the parent's dir ID, so the existence check of a folder of the name isn't sent.
		@Test
		func uploadFileCancelledWhileReadingParentDirIdSendsNoExistenceCheck() async throws {
			let fixture = try VaultFormat6Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			fixture.provider.transferHook = { _, _ in
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext3".write(to: localURL, atomically: true, encoding: .utf8)
			let decorator = fixture.decorator
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/Directory 1/File 3"), replaceExisting: false)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }
			#expect(fixture.provider.calls == ["downloadFile"])
		}

		/// The folder creation checks cancellation after its existence check, before its first remote change.
		@Test(arguments: Stacking.allCases)
		func createFolderCancelledDuringExistenceCheckCreatesNothing(stacking: Stacking) async throws {
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: vaultPath, cryptor: cryptor)
			fixture.provider.metadataHook = { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let decorator = fixture.decorator
			let creation = Task {
				try await decorator.createFolder(at: CloudPath("/Directory 2"))
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: creation) }
			#expect(fixture.provider.calls == ["fetchItemMetadata"])
			#expect(fixture.provider.createdFolders.isEmpty)
			#expect(fixture.provider.createdFiles.isEmpty)
		}

		/// The upload checks cancellation only after encrypting, not between the existence check and the encryption.
		@Test
		func uploadFileCancelledDuringExistenceCheckEncryptsBeforeThrowing() async throws {
			let fixture = try VaultFormat6Fixture(stacking: .plain, vaultPath: vaultPath, cryptor: cryptor)
			fixture.provider.metadataHook = { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let encryptions = OSAllocatedUnfairLock(initialState: 0)
			cryptor.encryptContentHook = { _, _ in
				encryptions.withLock { $0 += 1 }
			}
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext3".write(to: localURL, atomically: true, encoding: .utf8)
			let decorator = fixture.decorator
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/Directory 1/File 3"), replaceExisting: false)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }
			#expect(encryptions.withLock { $0 } == 1)
			#expect(fixture.provider.calls == ["downloadFile", "fetchItemMetadata"])
		}

		/// A prefix forms one `Character` with a combining mark after it, but it still marks the item type, and the encrypted name keeps the mark.
		@Test
		func parseCiphertextNameClassifiesByPrefixBytes() {
			#expect(parseVaultFormat6CiphertextName("0abc") == ("abc", .folder))
			#expect(parseVaultFormat6CiphertextName("1Sabc") == ("abc", .symlink))
			#expect(parseVaultFormat6CiphertextName("1abc") == ("1abc", .file))
			#expect(parseVaultFormat6CiphertextName("abc") == ("abc", .file))
			#expect(parseVaultFormat6CiphertextName("0\u{301}abc").baseName.utf8.elementsEqual("\u{301}abc".utf8))
			#expect(parseVaultFormat6CiphertextName("0\u{301}abc").itemType == .folder)
			#expect(parseVaultFormat6CiphertextName("1S\u{301}abc").baseName.utf8.elementsEqual("\u{301}abc".utf8))
			#expect(parseVaultFormat6CiphertextName("1S\u{301}abc").itemType == .symlink)
		}

		/// A prefix forms one `Character` with a combining mark after it, but the listing still classifies the item by it.
		@Test
		func fetchItemListClassifiesPrefixInCombinedCharacter() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: ["\(dirPath)/0\u{301}X": Data(), "\(dirPath)/1S\u{301}Y": Data()])
			let cryptor = CryptorMock(dirIds: ["": VaultTestFormat.encryptedRootDirId], fileNames: ["\u{301}X": "Folder", "\u{301}Y": "Link"], contents: [:])
			let decorator = try VaultFormat6ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect(itemList.items.map(\.name).sorted() == ["Folder", "Link"])
			#expect(itemList.items.first { $0.name == "Folder" }?.itemType == .folder)
			#expect(itemList.items.first { $0.name == "Link" }?.itemType == .symlink)
		}

		@Test
		func deleteFolderWithMissingDirFileThrowsItemNotFound() async throws {
			// pathToVault
			// └─Directory 1
			//   ├─ Directory 2
			//   └─ File 3
			let folders: Set = [
				"pathToVault",
				"pathToVault/d",
				"pathToVault/d/00",
				VaultTestFormat.rootDirectory,
				"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
				"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
			]
			let files = [
				"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": Data("dir2-id".utf8),
				"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3": Data("ciphertext3".utf8)
			]

			let provider = CloudProviderMock(folders: folders, files: files)
			let decorator = try VaultFormat6ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			await #expect(throws: CloudProviderError.itemNotFound) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(!provider.calls.contains("deleteFile"))
		}

		/// A listing leaves out a dir file whose name file can't be read, but a delete must not, because the dir file's directory would stay without a reference.
		@Test
		func deleteFolderWithUnreadableNameFileKeepsParent() async throws {
			let nameFilePath = "pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"
			let provider = makeNestedProvider(dirFiles: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": "dir2-id", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": "dir3-id"], files: [nameFilePath: Data("0\(String(repeating: "dir3", count: 33))".utf8)])
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == nameFilePath {
					throw CloudProviderError.quotaInsufficient
				}
			}
			let decorator = try makeShorteningDecorator(over: provider)
			await #expect(throws: CloudProviderError.quotaInsufficient) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(provider.deleted == ["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"])
		}

		/// The name file doesn't hold a name that shortens to its `.lng` name. The library addresses an item by shortening its name again, so it ignores the item, and the item's directory stays.
		@Test
		func deleteFolderWithInvalidNameFileIgnoresItem() async throws {
			let provider = makeNestedProvider(dirFiles: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": "dir3-id"], files: ["pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": Data("0dir3".utf8)])
			let decorator = try makeShorteningDecorator(over: provider)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "\(VaultTestFormat.rootDirectory)/0dir1"])
		}

		/// Old Cryptomator versions shortened names of 129 characters, which a listing moves to their original name.
		@Test
		func deleteFolderFollowsLegacyShortenedDirFileWithoutMovingIt() async throws {
			let provider = makeNestedProvider(dirFiles: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/NY7AR6SU3UK6BE5C526DHZZE7V72H2EV.lng": "dir3-id"], files: ["pathToVault/m/NY/7A/NY7AR6SU3UK6BE5C526DHZZE7V72H2EV.lng": Data("0\(String(repeating: "dir3", count: 32))".utf8)])
			let decorator = try makeShorteningDecorator(over: provider)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "\(VaultTestFormat.rootDirectory)/0dir1"])
			#expect(!provider.calls.contains("moveFile"))
		}

		/// The `0` prefix forms one `Character` with a combining mark after it, but it still marks a dir file.
		@Test(arguments: Stacking.allCases)
		func deleteFolderFollowsDirFileWhosePrefixIsInCombinedCharacter(stacking: Stacking) async throws {
			let provider = makeNestedProvider(dirFiles: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0\u{301}dir2": "dir2-id"])
			let decorator = stacking == .plain ? try VaultFormat6ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor) : try makeShorteningDecorator(over: provider)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "\(VaultTestFormat.rootDirectory)/0dir1"])
		}

		/// The `.lng` suffix forms one `Character` with a prepended mark before it, but it still marks a shortened name. This one isn't a valid one, so the delete ignores it and its directory stays.
		@Test
		func deleteFolderDoesNotFollowInvalidShortenedNameWhoseSuffixIsInCombinedCharacter() async throws {
			let provider = makeNestedProvider(dirFiles: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir3\u{600}.lng": "dir3-id"])
			let decorator = try makeShorteningDecorator(over: provider)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(provider.deleted == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "\(VaultTestFormat.rootDirectory)/0dir1"])
		}

		/// A shortcut named like a dir file downloads its target, which can name a directory outside the deleted folder. A shortened one is skipped before its `.lng` name file is read.
		@Test
		func deleteFolderDoesNotFollowShortenedAliasDirFile() async throws {
			let lngPath = "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"
			let provider = makeNestedProvider(dirFiles: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": "dir3-id"], files: ["pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": Data("0\(String(repeating: "dir3", count: 33))".utf8)], aliases: [lngPath])
			let (listedFolders, transferredFiles) = provider.recordingListingsAndTransfers()
			let decorator = try makeShorteningDecorator(over: provider)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(listedFolders.withLock { $0 } == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"])
			#expect(transferredFiles.withLock { $0 } == ["\(VaultTestFormat.rootDirectory)/0dir1"])
			#expect(provider.deleted == ["pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "\(VaultTestFormat.rootDirectory)/0dir1"])
		}

		// MARK: - Internal

		/// Returns a provider that holds `Directory 1`, the given dir files (by path below `pathToVault/d` and dir ID, replacing a default one) and the given files. The directories of `dir1-id` to `dir4-id` exist. A listing marks the items at the full paths of `aliases` as aliases, and a download those of `aliasedDownloads`.
		func makeNestedProvider(dirFiles: [String: String], files: [String: Data] = [:], aliases: Set<String> = [], aliasedDownloads: Set<String> = []) -> CloudProviderMock {
			let folders = Set(["pathToVault", "pathToVault/d"] + VaultTestFormat.nestedDirectories.map { "pathToVault/d/\($0)" })
			let references = ["\(VaultTestFormat.nestedDirectories[0])/0dir1": "dir1-id"].merging(dirFiles) { $1 }
			return CloudProviderMock(folders: folders, files: Dictionary(uniqueKeysWithValues: references.map { ("pathToVault/d/\($0.key)", Data($0.value.utf8)) }).merging(files) { $1 }, aliases: aliases, aliasedDownloads: aliasedDownloads)
		}

		func makeShorteningDecorator(over provider: CloudProvider) throws -> VaultFormat6ProviderDecorator {
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			return try VaultFormat6ProviderDecorator(shortening: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
		}
	}
}
