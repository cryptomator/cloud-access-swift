//
//  VaultFormat7ShorteningProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class VaultFormat7ShorteningProviderDecoratorTests {
		let vaultPath: CloudPath
		let cryptor: CryptorMock
		let tmpDirURL: URL
		var provider: CloudProviderMock
		var shorteningDecorator: VaultFormat7ShorteningProviderDecorator
		var decorator: VaultFormat7ProviderDecorator
		let file4C9SDirPath = "\(VaultTestFormat.rootDirectory)/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"
		let dir3C9SDirPath = "\(VaultTestFormat.rootDirectory)/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"
		/// The fixture holds `File 6 (Long)` only in `Directory 3 (Long)`, so its `.c9s` in the root doesn't exist.
		let rootFile6C9SDirPath = "\(VaultTestFormat.rootDirectory)/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s"
		/// The fixture holds `Directory 4 (Long)` only in `Directory 3 (Long)`, so its `.c9s` in the root doesn't exist.
		let rootDir4C9SDirPath = "\(VaultTestFormat.rootDirectory)/ImoW6Jb8d-kdR00uEadGd1_TJDM=.c9s"

		init() throws {
			let vaultPath = CloudPath("pathToVault")
			let cryptor = CryptorMock.vaultFormat7()
			let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			let fixture = try VaultFormat7Fixture(stacking: .shortening, vaultPath: vaultPath, cryptor: cryptor)
			self.vaultPath = vaultPath
			self.cryptor = cryptor
			self.tmpDirURL = tmpDirURL
			self.provider = fixture.provider
			self.shorteningDecorator = try #require(fixture.shorteningDecorator)
			self.decorator = fixture.decorator
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func fetchItemMetadataWithLongName() async throws {
			let metadata = try await decorator.fetchItemMetadata(at: CloudPath("/Directory 3 (Long)/File 6 (Long)"))
			#expect(metadata.name == "File 6 (Long)")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/Directory 3 (Long)/File 6 (Long)")
		}

		@Test
		func fetchItemListForSubDirWithLongName() async throws {
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 3 (Long)"), withPageToken: nil)
			#expect(itemList.items.count == 2)
			#expect(itemList.items.contains(where: { $0.name == "File 6 (Long)" }))
			#expect(itemList.items.contains(where: { $0.name == "Directory 4 (Long)" }))
		}

		@Test
		func fetchItemListWithCancelledNameLookup() async throws {
			let nameFilePath = "\(file4C9SDirPath)/name.c9s"
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == nameFilePath {
					throw CancellationError()
				}
			}
			await #expect(throws: CancellationError.self) { try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
		}

		@Test
		func fetchItemListWithOnlyInvalidNamesIsEmpty() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, "\(dirPath)/invalid.c9s"], files: [
				"\(dirPath)/invalid.c9s/name.c9s": Data("..".utf8),
				"\(dirPath)/invalid.c9s/contents.c9r": Data()
			])
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
			#expect(itemList.items.isEmpty)
		}

		/// The swapped name files hold valid names, so only the comparison with the listed name leaves their items out.
		@Test
		func fetchItemListSkipsNamesWhoseNameFileBelongsToAnotherName() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let longName = "\(String(repeating: "a", count: 217)).c9r"
			let ownDirPath = "\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
			let file5DirPath = "\(dirPath)/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, ownDirPath, file4C9SDirPath, file5DirPath], files: [
				"\(ownDirPath)/contents.c9r": Data(),
				"\(ownDirPath)/name.c9s": Data(longName.utf8),
				"\(file4C9SDirPath)/contents.c9r": Data(),
				"\(file4C9SDirPath)/name.c9s": Data("\(String(repeating: "file5", count: 44)).c9r".utf8),
				"\(file5DirPath)/contents.c9r": Data(),
				"\(file5DirPath)/name.c9s": Data("\(String(repeating: "file4", count: 44)).c9r".utf8)
			])
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
			#expect(itemList.items.map(\.cloudPath.path) == ["\(dirPath)/\(longName)"])
		}

		/// Both name files hold the name that hashes to their `.c9s` name, so only the size leaves the larger one out.
		@Test
		func fetchItemListSkipsNamesWhoseNameFileIsTooLarge() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let longestName = "\(String(repeating: "a", count: vaultNameFileMaxLength - ".c9r".count)).c9r"
			let longestDirPath = "\(dirPath)/-cQZZfpxsSDQPcuYRwOXtKmQoTU=.c9s"
			let tooLargeDirPath = "\(dirPath)/KOqmxbxIdVOtsmKM_zOEpV5IhKw=.c9s"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, longestDirPath, tooLargeDirPath], files: [
				"\(longestDirPath)/contents.c9r": Data(),
				"\(longestDirPath)/name.c9s": Data(longestName.utf8),
				"\(tooLargeDirPath)/contents.c9r": Data(),
				"\(tooLargeDirPath)/name.c9s": Data("\(String(repeating: "a", count: vaultNameFileMaxLength - ".c9r".count + 1)).c9r".utf8)
			])
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
			#expect(itemList.items.map(\.cloudPath.path) == ["\(dirPath)/\(longestName)"])
		}

		/// With one item per page, `name.c9s` fills the first page of the `.c9s` directory and `symlink.c9r` is on the second.
		@Test
		func fetchItemListFindsC9SItemOnLaterPage() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let longName = "\(String(repeating: "a", count: 217)).c9r"
			let c9sDirPath = "\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, c9sDirPath], files: [
				"\(c9sDirPath)/name.c9s": Data(longName.utf8),
				"\(c9sDirPath)/symlink.c9r": Data()
			], maxPageSize: 1)
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
			#expect(itemList.items.map(\.cloudPath.path) == ["\(dirPath)/\(longName)"])
			#expect(itemList.items.map(\.itemType) == [.symlink])
		}

		/// The invalid name is listed last, so the listing throws the lookup's error only if `invalidNameFile` is skipped.
		@Test
		func fetchItemListWithInvalidNamesAndFailedNameLookupThrows() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, "\(dirPath)/a-missing.c9s", "\(dirPath)/invalid.c9s"], files: [
				"\(dirPath)/a-missing.c9s/contents.c9r": Data(),
				"\(dirPath)/invalid.c9s/contents.c9r": Data(),
				"\(dirPath)/invalid.c9s/name.c9s": Data("..".utf8)
			])
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			await #expect(throws: CloudProviderError.itemNotFound) { try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil) }
		}

		/// The name file holds the name that hashes to the `.c9s` name, so only the missing item file leaves the `.c9s` out.
		@Test
		func fetchItemListWithOnlyC9SHoldingNameFileIsEmpty() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let c9sDirPath = "\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, c9sDirPath], files: [
				"\(c9sDirPath)/name.c9s": Data("\(String(repeating: "a", count: 217)).c9r".utf8)
			])
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
			#expect(itemList.items.isEmpty)
		}

		/// The `.c9s` suffix forms one `Character` with a prepended mark before it, but it still marks a `.c9s`, so the listing loads its name file. A missing name file fails the page, and an invalid one leaves the item out.
		@Test(arguments: [false, true])
		func fetchItemListLoadsNameFileOfC9SWhoseSuffixIsInCombinedCharacter(holdsNameFile: Bool) async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let c9sDirPath = "\(dirPath)/x\u{600}.c9s"
			let nameFile: [String: Data] = holdsNameFile ? ["\(c9sDirPath)/name.c9s": Data("\(String(repeating: "a", count: 217)).c9r".utf8)] : [:]
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, c9sDirPath], files: nameFile.merging(["\(c9sDirPath)/contents.c9r": Data()]) { $1 })
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			if holdsNameFile {
				let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
				#expect(itemList.items.isEmpty)
			} else {
				await #expect(throws: CloudProviderError.itemNotFound) { try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil) }
			}
		}

		@Test
		func fetchItemListWithOnlyEmptyC9SIsEmpty() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, "\(dirPath)/empty.c9s"], files: [:])
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
			#expect(itemList.items.isEmpty)
		}

		@Test
		func fetchItemListWithOnlyFileAtC9SNameIsEmpty() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: ["\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s": Data()])
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
			#expect(itemList.items.isEmpty)
		}

		@Test
		func fetchItemMetadataOfFileAtC9SNameThrowsItemNotFound() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: ["\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s": Data()])
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			await #expect(throws: CloudProviderError.itemNotFound) { try await shorteningDecorator.fetchItemMetadata(at: CloudPath("\(dirPath)/\(String(repeating: "a", count: 217)).c9r")) }
		}

		@Test
		func fetchItemMetadataOfC9SWithoutItemFileThrowsItemNotFound() async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let longName = "\(String(repeating: "a", count: 217)).c9r"
			let c9sDirPath = "\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, c9sDirPath], files: [
				"\(c9sDirPath)/name.c9s": Data(longName.utf8)
			])
			let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			await #expect(throws: CloudProviderError.itemNotFound) { try await shorteningDecorator.fetchItemMetadata(at: CloudPath("\(dirPath)/\(longName)")) }
		}

		@Test
		func downloadFileWithLongName() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let metadata = try await decorator.downloadFile(from: CloudPath("/File 4 (Long)"), to: localURL)
			let cleartext = try String(contentsOf: localURL, encoding: .utf8)
			#expect(cleartext == "cleartext4")
			#expect(metadata.name == "File 4 (Long)")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/File 4 (Long)")
			#expect(provider.lastModifiedDate == metadata.lastModifiedDate)
			#expect(metadata.size == 10)
		}

		@Test
		func uploadFileWithLongName() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext6".write(to: localURL, atomically: true, encoding: .utf8)
			let metadata = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 6 (Long)"), replaceExisting: false)
			#expect([rootFile6C9SDirPath] == provider.createdFolders)
			#expect(provider.createdFiles.count == 2)
			#expect(Data("ciphertext6".utf8) == provider.createdFiles["\(rootFile6C9SDirPath)/contents.c9r"])
			#expect(Data("\(String(repeating: "file6", count: 44)).c9r".utf8) == provider.createdFiles["\(rootFile6C9SDirPath)/name.c9s"])
			#expect(metadata.name == "File 6 (Long)")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/File 6 (Long)")
			#expect(provider.lastModifiedDate == metadata.lastModifiedDate)
			#expect(metadata.size == 0) // CryptorMock calculates a cleartext size of 0
		}

		@Test
		func uploadFileWithLongNameOverExistingFileWithReplaceExisting() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext5".write(to: localURL, atomically: true, encoding: .utf8)
			let metadata = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: true)
			#expect(["\(file4C9SDirPath)/contents.c9r": Data("ciphertext5".utf8)] == provider.createdFiles)
			#expect(provider.createdFolders == [])
			#expect(metadata.cloudPath.path == "/File 4 (Long)")
		}

		@Test
		func uploadFileWithLongNameOverExistingFileWithoutReplaceExistingThrowsItemAlreadyExists() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext5".write(to: localURL, atomically: true, encoding: .utf8)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false) }
			#expect(provider.createdFiles == [:])
		}

		/// A failed upload leaves a `.c9s` that holds only its name file, which a retried upload reuses.
		@Test
		func uploadFileWithLongNameToC9SHoldingOnlyNameFile() async throws {
			try rebuildProvider(changingFiles: ["\(file4C9SDirPath)/contents.c9r": nil])
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
			_ = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false)
			#expect(["\(file4C9SDirPath)/contents.c9r": Data("ciphertext4".utf8)] == provider.createdFiles)
		}

		@Test
		func uploadFileWithLongNameToEmptyC9SUploadsNameFile() async throws {
			try rebuildProvider(changingFiles: ["\(file4C9SDirPath)/contents.c9r": nil, "\(file4C9SDirPath)/name.c9s": nil])
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
			_ = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false)
			#expect(Data("ciphertext4".utf8) == provider.createdFiles["\(file4C9SDirPath)/contents.c9r"])
			#expect(Data("\(String(repeating: "file4", count: 44)).c9r".utf8) == provider.createdFiles["\(file4C9SDirPath)/name.c9s"])
		}

		@Test
		func uploadFileWithLongNameOverExistingFileWithoutNameFileUploadsNameFile() async throws {
			try rebuildProvider(changingFiles: ["\(file4C9SDirPath)/name.c9s": nil])
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
			_ = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: true)
			#expect(Data("\(String(repeating: "file4", count: 44)).c9r".utf8) == provider.createdFiles["\(file4C9SDirPath)/name.c9s"])
		}

		@Test
		func uploadFileWithLongNameOverFolderThrowsItemAlreadyExists() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await decorator.uploadFile(from: localURL, to: CloudPath("/Directory 3 (Long)"), replaceExisting: true) }
			#expect(provider.createdFiles == [:])
		}

		/// With one item per page, `name.c9s` fills the first page of the `.c9s` listing and `symlink.c9r` is on the second.
		@Test
		func uploadFileWithLongNameOverSymlinkThrowsItemAlreadyExists() async throws {
			try rebuildProvider(changingFiles: ["\(file4C9SDirPath)/contents.c9r": nil, "\(file4C9SDirPath)/symlink.c9r": Data()], maxPageSize: 1)
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: true) }
			#expect(provider.createdFiles == [:])
		}

		/// A file sits at the name of the root's `.c9s` of `File 6 (Long)`, so `createFolder` and the listing of that name both fail.
		@Test
		func uploadFileWithLongNameOverFileAtC9SNameThrowsItemAlreadyExists() async throws {
			try rebuildProvider(changingFiles: [rootFile6C9SDirPath: Data()])
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext6".write(to: localURL, atomically: true, encoding: .utf8)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await decorator.uploadFile(from: localURL, to: CloudPath("/File 6 (Long)"), replaceExisting: true) }
			#expect(provider.createdFiles == [:])
		}

		@Test
		func uploadFileWithLongNameOverExistingFileWithCancellationDuringC9SListing() async throws {
			let decorator: VaultFormat7ProviderDecorator = decorator
			let file4C9SDirPath = file4C9SDirPath
			provider.listingHook = { cloudPath, _ in
				if cloudPath.path == file4C9SDirPath {
					withUnsafeCurrentTask { $0?.cancel() }
				}
			}
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext5".write(to: localURL, atomically: true, encoding: .utf8)
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: true)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }
			#expect(!provider.calls.contains("uploadFile"))
		}

		@Test
		func uploadFileWithLongNameOverExistingFileWithCancellationAfterNameFileUpload() async throws {
			try rebuildProvider(changingFiles: ["\(file4C9SDirPath)/name.c9s": nil])
			let decorator: VaultFormat7ProviderDecorator = decorator
			provider.mutationHook = {
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext5".write(to: localURL, atomically: true, encoding: .utf8)
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: true)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }
			#expect(Array(provider.createdFiles.keys) == ["\(file4C9SDirPath)/name.c9s"])
		}

		@Test
		func createFolderWithLongName() async throws {
			try await decorator.createFolder(at: CloudPath("/Directory 4 (Long)"))
			#expect(provider.createdFolders.count == 3)
			#expect(provider.createdFolders.contains(rootDir4C9SDirPath))
			#expect(provider.createdFolders.contains("pathToVault/d/99"))
			#expect(provider.createdFolders.contains(VaultTestFormat.newDirectory))
			#expect(provider.createdFiles.count == 2)
			#expect(provider.createdFiles["\(rootDir4C9SDirPath)/dir.c9r"] != nil)
			#expect(Data("\(String(repeating: "dir4", count: 55)).c9r".utf8) == provider.createdFiles["\(rootDir4C9SDirPath)/name.c9s"])
		}

		@Test
		func deleteFileWithLongName() async throws {
			try await decorator.deleteFile(at: CloudPath("/Directory 3 (Long)/File 6 (Long)"))
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains("\(VaultTestFormat.directory3)/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s"))
		}

		@Test
		func deleteFolderWithLongName() async throws {
			try await decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)"))
			#expect(provider.deleted.count == 3)
			#expect(provider.deleted.contains(VaultTestFormat.directory4))
			#expect(provider.deleted.contains(VaultTestFormat.directory3))
			#expect(provider.deleted.contains(dir3C9SDirPath))
		}

		@Test
		func deleteFileWithLongNameWithDeletionIncompleteRestoresNameFile() async throws {
			provider.mutationFailure = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete)
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await decorator.deleteFile(at: CloudPath("/Directory 3 (Long)/File 6 (Long)")) }
			#expect(Data("\(String(repeating: "file6", count: 44)).c9r".utf8) == provider.createdFiles["\(VaultTestFormat.directory3)/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s/name.c9s"])
		}

		@Test
		func deleteFolderWithLongNameWithDeletionIncompleteRestoresNameFile() async throws {
			provider.mutationFailure = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: [dir3C9SDirPath])
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)")) }
			#expect(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8) == provider.createdFiles["\(dir3C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFileFromShortToLongName() async throws {
			try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/File 6 (Long)"))
			#expect(provider.createdFolders.count == 1)
			#expect(provider.createdFolders.contains(rootFile6C9SDirPath))
			#expect(provider.createdFiles.count == 1)
			#expect(Data("\(String(repeating: "file6", count: 44)).c9r".utf8) == provider.createdFiles["\(rootFile6C9SDirPath)/name.c9s"])
			#expect(provider.moved.count == 1)
			#expect(provider.moved["\(VaultTestFormat.rootDirectory)/file1.c9r"] == "\(rootFile6C9SDirPath)/contents.c9r")
		}

		@Test
		func moveFileFromLongToShortName() async throws {
			try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 3"))
			#expect(provider.moved.count == 1)
			#expect(provider.moved["\(file4C9SDirPath)/contents.c9r"] == "\(VaultTestFormat.rootDirectory)/file3.c9r")
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains(file4C9SDirPath))
		}

		@Test
		func moveFileFromLongToLongName() async throws {
			try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 6 (Long)"))
			#expect(provider.moved.count == 1)
			#expect(provider.moved[file4C9SDirPath] == rootFile6C9SDirPath)
			#expect(provider.createdFiles.count == 1)
			#expect(Data("\(String(repeating: "file6", count: 44)).c9r".utf8) == provider.createdFiles["\(rootFile6C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFolderFromShortToLongName() async throws {
			try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 4 (Long)"))
			#expect(provider.moved.count == 1)
			#expect(provider.moved["\(VaultTestFormat.rootDirectory)/dir1.c9r"] == rootDir4C9SDirPath)
			#expect(provider.createdFiles.count == 1)
			#expect(Data("\(String(repeating: "dir4", count: 55)).c9r".utf8) == provider.createdFiles["\(rootDir4C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFolderFromLongToShortName() async throws {
			try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 2"))
			#expect(provider.moved.count == 1)
			#expect(provider.moved[dir3C9SDirPath] == "\(VaultTestFormat.rootDirectory)/dir2.c9r")
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains("\(VaultTestFormat.rootDirectory)/dir2.c9r/name.c9s"))
		}

		@Test
		func moveFolderFromShortToLongNameWithMoveCompletedUploadsNameFileAndRethrows() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 4 (Long)")) }
			#expect(Data("\(String(repeating: "dir4", count: 55)).c9r".utf8) == provider.createdFiles["\(rootDir4C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFolderWithMoveCompletedAndFailedNameFileUploadThrowsUploadError() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			provider.transferHook = { cloudPath, _ in
				if cloudPath.lastPathComponent == "name.c9s" {
					throw CloudProviderError.quotaInsufficient
				}
			}
			await #expect(throws: CloudProviderError.quotaInsufficient) { try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 4 (Long)")) }
		}

		@Test
		func moveFolderFromLongToShortNameWithMoveCompletedDeletesNameFileAndRethrows() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 2")) }
			#expect(provider.deleted == ["\(VaultTestFormat.rootDirectory)/dir2.c9r/name.c9s"])
		}

		/// The stale name file is never read, so failing to delete it doesn't replace the move's outcome.
		@Test
		func moveFolderFromLongToShortNameWithMoveCompletedAndFailedNameFileDeleteRethrowsMoveCompleted() async throws {
			provider.mutationFailure = { call, _ in
				switch call {
				case "moveFolder": return CloudProviderError.moveCompletedWithSourceRemaining
				case "deleteFile": return CloudProviderError.noInternetConnection
				default: return nil
				}
			}
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 2")) }
		}

		@Test
		func moveFolderFromLongToShortNameWithMoveCompletedAndCancelledNameFileDeleteThrowsCancellationError() async throws {
			provider.mutationFailure = { call, _ in
				switch call {
				case "moveFolder": return CloudProviderError.moveCompletedWithSourceRemaining
				case "deleteFile": return CancellationError()
				default: return nil
				}
			}
			await #expect(throws: CancellationError.self) { try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 2")) }
		}

		/// The stale name file is never read, so a refused delete of it leaves nothing to report.
		@Test
		func moveFolderFromLongToShortNameWithRefusedNameFileDeleteSucceeds() async throws {
			provider.mutationFailure = CloudProviderMock.failing("deleteFile", with: CloudProviderError.deletionIncomplete)
			try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 2"))
			#expect(provider.moved[dir3C9SDirPath] == "\(VaultTestFormat.rootDirectory)/dir2.c9r")
		}

		@Test
		func moveFileFromLongToShortNameWithRefusedSourceDeleteThrowsMoveCompleted() async throws {
			provider.mutationFailure = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 3")) }
		}

		@Test
		func moveFileFromLongToShortNameWithMoveCompletedKeepsSource() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFile", with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 3")) }
			#expect(provider.deleted == [])
		}

		@Test
		func moveFileFromLongToLongNameWithMoveCompletedUploadsNameFileAndRethrows() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 6 (Long)")) }
			#expect(Data("\(String(repeating: "file6", count: 44)).c9r".utf8) == provider.createdFiles["\(rootFile6C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFileFromLongToLongNameWithMoveCompletedRestoresSourceNameFile() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 6 (Long)")) }
			#expect(Data("\(String(repeating: "file4", count: 44)).c9r".utf8) == provider.createdFiles["\(file4C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFolderFromLongToShortNameWithMoveCompletedRestoresSourceNameFile() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 2")) }
			#expect(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8) == provider.createdFiles["\(dir3C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFolderFromLongToLongNameWithMoveCompletedRestoresSourceNameFile() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1/Directory 4 (Long)")) }
			#expect(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8) == provider.createdFiles["\(dir3C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFileFromLongToLongNameWithMoveCompletedAndFailedTargetNameFileUploadRestoresSourceNameFile() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			let targetNameFilePath = "\(rootFile6C9SDirPath)/name.c9s"
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == targetNameFilePath {
					throw CloudProviderError.quotaInsufficient
				}
			}
			await #expect(throws: CloudProviderError.quotaInsufficient) { try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 6 (Long)")) }
			#expect(Data("\(String(repeating: "file4", count: 44)).c9r".utf8) == provider.createdFiles["\(file4C9SDirPath)/name.c9s"])
		}

		/// The target is complete, so failing to restore the source's name file doesn't replace the move's outcome.
		@Test
		func moveFileFromLongToLongNameWithMoveCompletedAndFailedSourceNameFileUploadRethrowsMoveCompleted() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			let failedSourceNameFileUploads = OSAllocatedUnfairLock(initialState: 0)
			let sourceNameFilePath = "\(file4C9SDirPath)/name.c9s"
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == sourceNameFilePath {
					failedSourceNameFileUploads.withLock { $0 += 1 }
					throw CloudProviderError.quotaInsufficient
				}
			}
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 6 (Long)")) }
			#expect(failedSourceNameFileUploads.withLock { $0 } == 1)
		}

		@Test
		func moveFileFromLongToLongNameWithMoveCompletedAndCancelledSourceNameFileUploadThrowsCancellationError() async throws {
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			let sourceNameFilePath = "\(file4C9SDirPath)/name.c9s"
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == sourceNameFilePath {
					throw CancellationError()
				}
			}
			await #expect(throws: CancellationError.self) { try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 6 (Long)")) }
		}

		@Test
		func uploadFileWithLongNameWithCancellationAfterFirstRemoteChange() async throws {
			let decorator: VaultFormat7ProviderDecorator = decorator
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext6".write(to: localURL, atomically: true, encoding: .utf8)
			let metadata = try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File 6 (Long)"), replaceExisting: false)
			}
			#expect([rootFile6C9SDirPath] == provider.createdFolders)
			#expect(Data("\(String(repeating: "file6", count: 44)).c9r".utf8) == provider.createdFiles["\(rootFile6C9SDirPath)/name.c9s"])
			#expect(Data("ciphertext6".utf8) == provider.createdFiles["\(rootFile6C9SDirPath)/contents.c9r"])
			#expect(metadata.cloudPath.path == "/File 6 (Long)")
		}

		@Test
		func createFolderWithLongNameWithCancellationAfterFirstRemoteChange() async throws {
			let shorteningDecorator: VaultFormat7ShorteningProviderDecorator = shorteningDecorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await shorteningDecorator.createFolder(at: CloudPath("\(VaultTestFormat.rootDirectory)/\(String(repeating: "dir4", count: 55)).c9r"))
			}
			#expect(provider.createdFolders == [rootDir4C9SDirPath])
			#expect(Data("\(String(repeating: "dir4", count: 55)).c9r".utf8) == provider.createdFiles["\(rootDir4C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFileFromShortToLongNameWithCancellationAfterFirstRemoteChange() async throws {
			let decorator: VaultFormat7ProviderDecorator = decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/File 6 (Long)"))
			}
			#expect(Data("\(String(repeating: "file6", count: 44)).c9r".utf8) == provider.createdFiles["\(rootFile6C9SDirPath)/name.c9s"])
			#expect(provider.moved["\(VaultTestFormat.rootDirectory)/file1.c9r"] == "\(rootFile6C9SDirPath)/contents.c9r")
		}

		@Test
		func moveFileFromLongToShortNameWithCancellationAfterFirstRemoteChange() async throws {
			let decorator: VaultFormat7ProviderDecorator = decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 3"))
			}
			#expect(provider.moved["\(file4C9SDirPath)/contents.c9r"] == "\(VaultTestFormat.rootDirectory)/file3.c9r")
			#expect(provider.deleted == [file4C9SDirPath])
		}

		@Test
		func moveFileFromLongToLongNameWithCancellationAfterFirstRemoteChange() async throws {
			let decorator: VaultFormat7ProviderDecorator = decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 6 (Long)"))
			}
			#expect(provider.moved[file4C9SDirPath] == rootFile6C9SDirPath)
			#expect(Data("\(String(repeating: "file6", count: 44)).c9r".utf8) == provider.createdFiles["\(rootFile6C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFolderFromShortToLongNameWithCancellationAfterFirstRemoteChange() async throws {
			let decorator: VaultFormat7ProviderDecorator = decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 4 (Long)"))
			}
			#expect(provider.moved["\(VaultTestFormat.rootDirectory)/dir1.c9r"] == rootDir4C9SDirPath)
			#expect(Data("\(String(repeating: "dir4", count: 55)).c9r".utf8) == provider.createdFiles["\(rootDir4C9SDirPath)/name.c9s"])
		}

		@Test
		func moveFolderFromLongToShortNameWithCancellationAfterFirstRemoteChange() async throws {
			let decorator: VaultFormat7ProviderDecorator = decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 2"))
			}
			#expect(provider.moved[dir3C9SDirPath] == "\(VaultTestFormat.rootDirectory)/dir2.c9r")
			#expect(provider.deleted == ["\(VaultTestFormat.rootDirectory)/dir2.c9r/name.c9s"])
		}

		@Test
		func moveFolderFromLongToLongNameWithCancellationAfterFirstRemoteChange() async throws {
			let decorator: VaultFormat7ProviderDecorator = decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1/Directory 4 (Long)"))
			}
			#expect(provider.moved.count == 1)
			#expect([Data("\(String(repeating: "dir4", count: 55)).c9r".utf8)] == Array(provider.createdFiles.values))
		}

		@Test
		func shorteningDecoratorThrowsCancellationErrorInCancelledTask() async {
			await assertThrowsCancellationErrorInCancelledTask(shorteningDecorator)
			#expect(provider.calls == [])
		}

		// MARK: - Internal

		/// Replaces the provider with one that holds the current items with `changedFiles` applied, where a `nil` value removes a file, and rebuilds the decorators over it. The new provider's records start empty.
		private func rebuildProvider(changingFiles changedFiles: [String: Data?], maxPageSize: Int = .max) throws {
			var files = provider.files
			for (path, data) in changedFiles {
				files[path] = data
			}
			provider = CloudProviderMock(folders: provider.folders, files: files, maxPageSize: maxPageSize)
			shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			decorator = try VaultFormat7ProviderDecorator(shortening: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
		}
	}
}
