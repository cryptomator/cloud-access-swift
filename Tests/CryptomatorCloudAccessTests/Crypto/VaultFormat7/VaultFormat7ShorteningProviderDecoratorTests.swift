//
//  VaultFormat7ShorteningProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
@testable import CryptomatorCloudAccessCore

class VaultFormat7ShorteningProviderDecoratorTests: VaultFormat7ProviderDecoratorTests {
	var shorteningDecorator: VaultFormat7ShorteningProviderDecorator!
	let file4C9SDirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"
	/// The fixture holds `File 6 (Long)` only in `Directory 3 (Long)`, so its `.c9s` in the root doesn't exist.
	let rootFile6C9SDirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s"

	override func setUpWithError() throws {
		try super.setUpWithError()
		shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		decorator = try VaultFormat7ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
	}

	override func tearDownWithError() throws {
		shorteningDecorator = nil
		try super.tearDownWithError()
	}

	override func testTemporaryDirectoryLiesInProcessFolder() throws {
		try super.testTemporaryDirectoryLiesInProcessFolder()
		XCTAssertEqual(try ProcessTemporaryDirectory.shared.directoryURL().path, shorteningDecorator.tmpDirURL.deletingLastPathComponent().path)
	}

	override func testFetchItemListForRootDir() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		XCTAssertEqual(6, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 1" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 3 (Long)" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 1" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 2" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 4 (Long)" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 5 (Long)" }))
	}

	func testFetchItemMetadataWithLongName() async throws {
		let metadata = try await decorator.fetchItemMetadata(at: CloudPath("/Directory 3 (Long)/File 6 (Long)"))
		XCTAssertEqual("File 6 (Long)", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/Directory 3 (Long)/File 6 (Long)", metadata.cloudPath.path)
	}

	func testFetchItemListForSubDirWithLongName() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 3 (Long)"), withPageToken: nil)
		XCTAssertEqual(2, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 6 (Long)" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 4 (Long)" }))
	}

	func testFetchItemListWithCancelledNameLookup() async throws {
		provider.transferHook = { cloudPath, _ in
			if cloudPath.path == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s" {
				throw CancellationError()
			}
		}
		await XCTAssertThrowsErrorAsync(try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}

	func testFetchItemListWithOnlyInvalidNamesIsEmpty() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, "\(dirPath)/invalid.c9s"], files: [
			"\(dirPath)/invalid.c9s/name.c9s": Data("..".utf8),
			"\(dirPath)/invalid.c9s/contents.c9r": Data()
		])
		let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
		XCTAssertTrue(itemList.items.isEmpty)
	}

	/// The swapped name files hold valid names, so only the comparison with the listed name leaves their items out.
	func testFetchItemListSkipsNamesWhoseNameFileBelongsToAnotherName() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let longName = "\(String(repeating: "a", count: 217)).c9r"
		let ownDirPath = "\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
		let file4DirPath = "\(dirPath)/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"
		let file5DirPath = "\(dirPath)/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, ownDirPath, file4DirPath, file5DirPath], files: [
			"\(ownDirPath)/contents.c9r": Data(),
			"\(ownDirPath)/name.c9s": Data(longName.utf8),
			"\(file4DirPath)/contents.c9r": Data(),
			"\(file4DirPath)/name.c9s": Data("\(String(repeating: "file5", count: 44)).c9r".utf8),
			"\(file5DirPath)/contents.c9r": Data(),
			"\(file5DirPath)/name.c9s": Data("\(String(repeating: "file4", count: 44)).c9r".utf8)
		])
		let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
		XCTAssertEqual(["\(dirPath)/\(longName)"], itemList.items.map(\.cloudPath.path))
	}

	/// With one item per page, `name.c9s` fills the first page of the `.c9s` directory and `symlink.c9r` is on the second.
	func testFetchItemListFindsC9SItemOnLaterPage() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let longName = "\(String(repeating: "a", count: 217)).c9r"
		let c9sDirPath = "\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, c9sDirPath], files: [
			"\(c9sDirPath)/name.c9s": Data(longName.utf8),
			"\(c9sDirPath)/symlink.c9r": Data()
		], maxPageSize: 1)
		let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
		XCTAssertEqual(["\(dirPath)/\(longName)"], itemList.items.map(\.cloudPath.path))
		XCTAssertEqual([.symlink], itemList.items.map(\.itemType))
	}

	/// The invalid name is listed last, so the listing throws the lookup's error only if `invalidNameFile` is skipped.
	func testFetchItemListWithInvalidNamesAndFailedNameLookupThrows() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, "\(dirPath)/a-missing.c9s", "\(dirPath)/invalid.c9s"], files: [
			"\(dirPath)/a-missing.c9s/contents.c9r": Data(),
			"\(dirPath)/invalid.c9s/contents.c9r": Data(),
			"\(dirPath)/invalid.c9s/name.c9s": Data("..".utf8)
		])
		let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		await XCTAssertThrowsErrorAsync(try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	/// The name file holds the name that hashes to the `.c9s` name, so only the missing item file leaves the `.c9s` out.
	func testFetchItemListWithOnlyC9SHoldingNameFileIsEmpty() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let c9sDirPath = "\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, c9sDirPath], files: [
			"\(c9sDirPath)/name.c9s": Data("\(String(repeating: "a", count: 217)).c9r".utf8)
		])
		let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
		XCTAssertTrue(itemList.items.isEmpty)
	}

	func testFetchItemListWithOnlyEmptyC9SIsEmpty() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, "\(dirPath)/empty.c9s"], files: [:])
		let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
		XCTAssertTrue(itemList.items.isEmpty)
	}

	func testFetchItemListWithOnlyFileAtC9SNameIsEmpty() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: ["\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s": Data()])
		let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
		XCTAssertTrue(itemList.items.isEmpty)
	}

	func testFetchItemMetadataOfFileAtC9SNameThrowsItemNotFound() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: ["\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s": Data()])
		let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		await XCTAssertThrowsErrorAsync(try await shorteningDecorator.fetchItemMetadata(at: CloudPath("\(dirPath)/\(String(repeating: "a", count: 217)).c9r"))) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testFetchItemMetadataOfC9SWithoutItemFileThrowsItemNotFound() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let longName = "\(String(repeating: "a", count: 217)).c9r"
		let c9sDirPath = "\(dirPath)/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath, c9sDirPath], files: [
			"\(c9sDirPath)/name.c9s": Data(longName.utf8)
		])
		let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		await XCTAssertThrowsErrorAsync(try await shorteningDecorator.fetchItemMetadata(at: CloudPath("\(dirPath)/\(longName)"))) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithLongName() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let metadata = try await decorator.downloadFile(from: CloudPath("/File 4 (Long)"), to: localURL)
		let cleartext = try String(contentsOf: localURL, encoding: .utf8)
		XCTAssertEqual("cleartext4", cleartext)
		XCTAssertEqual("File 4 (Long)", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 4 (Long)", metadata.cloudPath.path)
		XCTAssertEqual(provider.lastModifiedDate, metadata.lastModifiedDate)
		XCTAssertEqual(10, metadata.size)
	}

	func testUploadFileWithLongName() async throws {
		try useProviderRejectingExistingItems()
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext6".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 6 (Long)"), replaceExisting: false)
		XCTAssertEqual([rootFile6C9SDirPath], provider.createdFolders)
		XCTAssertEqual(2, provider.createdFiles.count)
		XCTAssertEqual(Data("ciphertext6".utf8), provider.createdFiles["\(rootFile6C9SDirPath)/contents.c9r"])
		XCTAssertEqual(Data("\(String(repeating: "file6", count: 44)).c9r".utf8), provider.createdFiles["\(rootFile6C9SDirPath)/name.c9s"])
		XCTAssertEqual("File 6 (Long)", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 6 (Long)", metadata.cloudPath.path)
		XCTAssertEqual(provider.lastModifiedDate, metadata.lastModifiedDate)
		XCTAssertEqual(0, metadata.size) // CryptorMock calculates a cleartext size of 0
	}

	func testUploadFileWithLongNameOverExistingFileWithReplaceExisting() async throws {
		try useProviderRejectingExistingItems()
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext5".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: true)
		XCTAssertEqual(["\(file4C9SDirPath)/contents.c9r": Data("ciphertext5".utf8)], provider.createdFiles)
		XCTAssertEqual([], provider.createdFolders)
		XCTAssertEqual("/File 4 (Long)", metadata.cloudPath.path)
	}

	func testUploadFileWithLongNameOverExistingFileWithoutReplaceExistingThrowsItemAlreadyExists() async throws {
		try useProviderRejectingExistingItems()
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext5".write(to: localURL, atomically: true, encoding: .utf8)
		await XCTAssertThrowsErrorAsync(try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false)) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
		XCTAssertEqual([:], provider.createdFiles)
	}

	/// A failed upload leaves a `.c9s` that holds only its name file, which a retried upload reuses.
	func testUploadFileWithLongNameToC9SHoldingOnlyNameFile() async throws {
		try useProviderRejectingExistingItems(changingFiles: ["\(file4C9SDirPath)/contents.c9r": nil])
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		_ = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false)
		XCTAssertEqual(["\(file4C9SDirPath)/contents.c9r": Data("ciphertext4".utf8)], provider.createdFiles)
	}

	func testUploadFileWithLongNameToEmptyC9SUploadsNameFile() async throws {
		try useProviderRejectingExistingItems(changingFiles: ["\(file4C9SDirPath)/contents.c9r": nil, "\(file4C9SDirPath)/name.c9s": nil])
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		_ = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false)
		XCTAssertEqual(Data("ciphertext4".utf8), provider.createdFiles["\(file4C9SDirPath)/contents.c9r"])
		XCTAssertEqual(Data("\(String(repeating: "file4", count: 44)).c9r".utf8), provider.createdFiles["\(file4C9SDirPath)/name.c9s"])
	}

	func testUploadFileWithLongNameOverExistingFileWithoutNameFileUploadsNameFile() async throws {
		try useProviderRejectingExistingItems(changingFiles: ["\(file4C9SDirPath)/name.c9s": nil])
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		_ = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: true)
		XCTAssertEqual(Data("\(String(repeating: "file4", count: 44)).c9r".utf8), provider.createdFiles["\(file4C9SDirPath)/name.c9s"])
	}

	func testUploadFileWithLongNameOverFolderThrowsItemAlreadyExists() async throws {
		try useProviderRejectingExistingItems()
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		await XCTAssertThrowsErrorAsync(try await decorator.uploadFile(from: localURL, to: CloudPath("/Directory 3 (Long)"), replaceExisting: true)) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
		XCTAssertEqual([:], provider.createdFiles)
	}

	/// With one item per page, `name.c9s` fills the first page of the `.c9s` listing and `symlink.c9r` is on the second.
	func testUploadFileWithLongNameOverSymlinkThrowsItemAlreadyExists() async throws {
		try useProviderRejectingExistingItems(changingFiles: ["\(file4C9SDirPath)/contents.c9r": nil, "\(file4C9SDirPath)/symlink.c9r": Data()], maxPageSize: 1)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		await XCTAssertThrowsErrorAsync(try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: true)) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
		XCTAssertEqual([:], provider.createdFiles)
	}

	/// A file sits at the name of the root's `.c9s` of `File 6 (Long)`, so `createFolder` and the listing of that name both fail.
	func testUploadFileWithLongNameOverFileAtC9SNameThrowsItemAlreadyExists() async throws {
		try useProviderRejectingExistingItems(changingFiles: [rootFile6C9SDirPath: Data()])
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext6".write(to: localURL, atomically: true, encoding: .utf8)
		await XCTAssertThrowsErrorAsync(try await decorator.uploadFile(from: localURL, to: CloudPath("/File 6 (Long)"), replaceExisting: true)) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
		XCTAssertEqual([:], provider.createdFiles)
	}

	func testUploadFileWithLongNameOverExistingFileWithCancellationDuringC9SListing() async throws {
		try useProviderRejectingExistingItems()
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
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertFalse(provider.calls.contains("uploadFile"))
	}

	func testUploadFileWithLongNameOverExistingFileWithCancellationAfterNameFileUpload() async throws {
		try useProviderRejectingExistingItems(changingFiles: ["\(file4C9SDirPath)/name.c9s": nil])
		let decorator: VaultFormat7ProviderDecorator = decorator
		provider.mutationHook = {
			withUnsafeCurrentTask { $0?.cancel() }
		}
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext5".write(to: localURL, atomically: true, encoding: .utf8)
		let upload = Task {
			try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: true)
		}
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(["\(file4C9SDirPath)/name.c9s"], Array(provider.createdFiles.keys))
	}

	func testCreateFolderWithLongName() async throws {
		try await decorator.createFolder(at: CloudPath("/Directory 3 (Long)"))
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
		XCTAssertEqual(2, provider.createdFiles.count)
		XCTAssertNotNil(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/dir.c9r"])
		XCTAssertEqual(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"])
	}

	func testDeleteFileWithLongName() async throws {
		try await decorator.deleteFile(at: CloudPath("/Directory 3 (Long)/File 6 (Long)"))
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s"))
	}

	func testDeleteFolderWithLongName() async throws {
		try await decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)"))
		XCTAssertEqual(3, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"))
	}

	func testDeleteFileWithLongNameWithDeletionIncompleteRestoresNameFile() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete)
		await XCTAssertThrowsErrorAsync(try await decorator.deleteFile(at: CloudPath("/Directory 3 (Long)/File 6 (Long)"))) { error in
			XCTAssertEqual(CloudProviderError.deletionIncomplete, error as? CloudProviderError)
		}
		XCTAssertEqual(Data("\(String(repeating: "file6", count: 44)).c9r".utf8), provider.createdFiles["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s/name.c9s"])
	}

	func testDeleteFolderWithLongNameWithDeletionIncompleteRestoresNameFile() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"])
		await XCTAssertThrowsErrorAsync(try await decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)"))) { error in
			XCTAssertEqual(CloudProviderError.deletionIncomplete, error as? CloudProviderError)
		}
		XCTAssertEqual(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"])
	}

	func testMoveFileFromShortToLongName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/File 4 (Long)"))
		XCTAssertEqual(1, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual(Data("\(String(repeating: "file4", count: 44)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s"])
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"])
	}

	func testMoveFileFromLongToShortName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 1"))
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r"])
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"))
	}

	func testMoveFileFromLongToLongName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)"))
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"])
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual(Data("\(String(repeating: "file5", count: 44)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/name.c9s"])
	}

	func testMoveFolderFromShortToLongName() async throws {
		try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 3 (Long)"))
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"])
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"])
	}

	func testMoveFolderFromLongToShortName() async throws {
		try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1"))
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"])
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/name.c9s"))
	}

	func testMoveFolderFromShortToLongNameWithMoveCompletedUploadsNameFileAndRethrows() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		await XCTAssertThrowsErrorAsync(try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 3 (Long)"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
		XCTAssertEqual(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"])
	}

	func testMoveFolderWithMoveCompletedAndFailedNameFileUploadThrowsUploadError() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		provider.transferHook = { cloudPath, _ in
			if cloudPath.lastPathComponent == "name.c9s" {
				throw CloudProviderError.quotaInsufficient
			}
		}
		await XCTAssertThrowsErrorAsync(try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 3 (Long)"))) { error in
			XCTAssertEqual(CloudProviderError.quotaInsufficient, error as? CloudProviderError)
		}
	}

	func testMoveFolderFromLongToShortNameWithMoveCompletedDeletesNameFileAndRethrows() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		await XCTAssertThrowsErrorAsync(try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/name.c9s"], provider.deleted)
	}

	/// The stale name file is never read, so failing to delete it doesn't replace the move's outcome.
	func testMoveFolderFromLongToShortNameWithMoveCompletedAndFailedNameFileDeleteRethrowsMoveCompleted() async throws {
		provider.afterMutationHook = { call, _ in
			switch call {
			case "moveFolder": throw CloudProviderError.moveCompletedWithSourceRemaining
			case "deleteFile": throw CloudProviderError.noInternetConnection
			default: break
			}
		}
		await XCTAssertThrowsErrorAsync(try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
	}

	func testMoveFolderFromLongToShortNameWithMoveCompletedAndCancelledNameFileDeleteThrowsCancellationError() async throws {
		provider.afterMutationHook = { call, _ in
			switch call {
			case "moveFolder": throw CloudProviderError.moveCompletedWithSourceRemaining
			case "deleteFile": throw CancellationError()
			default: break
			}
		}
		await XCTAssertThrowsErrorAsync(try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1"))) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
	}

	/// The stale name file is never read, so a refused delete of it leaves nothing to report.
	func testMoveFolderFromLongToShortNameWithRefusedNameFileDeleteSucceeds() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("deleteFile", with: CloudProviderError.deletionIncomplete)
		try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1"))
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"])
	}

	func testMoveFileFromLongToShortNameWithRefusedSourceDeleteThrowsMoveCompleted() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete)
		await XCTAssertThrowsErrorAsync(try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 1"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
	}

	func testMoveFileFromLongToShortNameWithMoveCompletedKeepsSource() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFile", with: CloudProviderError.moveCompletedWithSourceRemaining)
		await XCTAssertThrowsErrorAsync(try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 1"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
		XCTAssertEqual([], provider.deleted)
	}

	func testMoveFileFromLongToLongNameWithMoveCompletedUploadsNameFileAndRethrows() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		await XCTAssertThrowsErrorAsync(try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
		XCTAssertEqual(Data("\(String(repeating: "file5", count: 44)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/name.c9s"])
	}

	func testMoveFileFromLongToLongNameWithMoveCompletedRestoresSourceNameFile() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		await XCTAssertThrowsErrorAsync(try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
		XCTAssertEqual(Data("\(String(repeating: "file4", count: 44)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s"])
	}

	func testMoveFolderFromLongToShortNameWithMoveCompletedRestoresSourceNameFile() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		await XCTAssertThrowsErrorAsync(try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
		XCTAssertEqual(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"])
	}

	func testMoveFolderFromLongToLongNameWithMoveCompletedRestoresSourceNameFile() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		await XCTAssertThrowsErrorAsync(try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1/Directory 4 (Long)"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
		XCTAssertEqual(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"])
	}

	func testMoveFileFromLongToLongNameWithMoveCompletedAndFailedTargetNameFileUploadRestoresSourceNameFile() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		provider.transferHook = { cloudPath, _ in
			if cloudPath.path == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/name.c9s" {
				throw CloudProviderError.quotaInsufficient
			}
		}
		await XCTAssertThrowsErrorAsync(try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)"))) { error in
			XCTAssertEqual(CloudProviderError.quotaInsufficient, error as? CloudProviderError)
		}
		XCTAssertEqual(Data("\(String(repeating: "file4", count: 44)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s"])
	}

	/// The target is complete, so failing to restore the source's name file doesn't replace the move's outcome.
	func testMoveFileFromLongToLongNameWithMoveCompletedAndFailedSourceNameFileUploadRethrowsMoveCompleted() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		provider.transferHook = { cloudPath, _ in
			if cloudPath.path == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s" {
				throw CloudProviderError.quotaInsufficient
			}
		}
		await XCTAssertThrowsErrorAsync(try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)"))) { error in
			XCTAssertEqual(CloudProviderError.moveCompletedWithSourceRemaining, error as? CloudProviderError)
		}
	}

	func testMoveFileFromLongToLongNameWithMoveCompletedAndCancelledSourceNameFileUploadThrowsCancellationError() async throws {
		provider.afterMutationHook = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
		provider.transferHook = { cloudPath, _ in
			if cloudPath.path == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s" {
				throw CancellationError()
			}
		}
		await XCTAssertThrowsErrorAsync(try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)"))) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
	}

	func testUploadFileWithLongNameWithCancellationAfterFirstRemoteChange() async throws {
		try useProviderRejectingExistingItems()
		let decorator: VaultFormat7ProviderDecorator = decorator
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext6".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.uploadFile(from: localURL, to: CloudPath("/File 6 (Long)"), replaceExisting: false)
		}
		XCTAssertEqual([rootFile6C9SDirPath], provider.createdFolders)
		XCTAssertEqual(Data("\(String(repeating: "file6", count: 44)).c9r".utf8), provider.createdFiles["\(rootFile6C9SDirPath)/name.c9s"])
		XCTAssertEqual(Data("ciphertext6".utf8), provider.createdFiles["\(rootFile6C9SDirPath)/contents.c9r"])
		XCTAssertEqual("/File 6 (Long)", metadata.cloudPath.path)
	}

	func testCreateFolderWithLongNameWithCancellationAfterFirstRemoteChange() async throws {
		let shorteningDecorator: VaultFormat7ShorteningProviderDecorator = shorteningDecorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await shorteningDecorator.createFolder(at: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/\(String(repeating: "dir3", count: 55)).c9r"))
		}
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"], provider.createdFolders)
		XCTAssertEqual(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"])
	}

	func testMoveFileFromShortToLongNameWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/File 4 (Long)"))
		}
		XCTAssertEqual(Data("\(String(repeating: "file4", count: 44)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s"])
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"])
	}

	func testMoveFileFromLongToShortNameWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 1"))
		}
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r"])
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"], provider.deleted)
	}

	func testMoveFileFromLongToLongNameWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)"))
		}
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"])
		XCTAssertEqual(Data("\(String(repeating: "file5", count: 44)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/name.c9s"])
	}

	func testMoveFolderFromShortToLongNameWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 3 (Long)"))
		}
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"])
		XCTAssertEqual(Data("\(String(repeating: "dir3", count: 55)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"])
	}

	func testMoveFolderFromLongToShortNameWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1"))
		}
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"])
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/name.c9s"], provider.deleted)
	}

	func testMoveFolderFromLongToLongNameWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1/Directory 4 (Long)"))
		}
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual([Data("\(String(repeating: "dir4", count: 55)).c9r".utf8)], Array(provider.createdFiles.values))
	}

	func testShorteningDecoratorThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(shorteningDecorator)
		XCTAssertEqual([], provider.calls)
	}

	// MARK: - Internal

	/// Replaces the provider with one that rejects existing items, and rebuilds the decorators over it. `changedFiles` changes its fixture files, and a `nil` value removes a file.
	private func useProviderRejectingExistingItems(changingFiles changedFiles: [String: Data?] = [:], maxPageSize: Int = .max) throws {
		var files = provider.files
		for (path, data) in changedFiles {
			files[path] = data
		}
		provider = VaultFormat7CloudProviderMock(folders: provider.folders, files: files, maxPageSize: maxPageSize, rejectsExistingItems: true)
		shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		decorator = try VaultFormat7ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
	}
}
