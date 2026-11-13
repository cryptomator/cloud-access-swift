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
			"\(dirPath)/invalid.c9s/name.c9s": Data("..".utf8)
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
			"\(dirPath)/invalid.c9s/name.c9s": Data("..".utf8)
		])
		let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		await XCTAssertThrowsErrorAsync(try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)) { error in
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
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false)
		XCTAssertEqual(2, provider.createdFiles.count)
		XCTAssertEqual(Data("ciphertext4".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r"])
		XCTAssertEqual(Data("\(String(repeating: "file4", count: 44)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s"])
		XCTAssertEqual("File 4 (Long)", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 4 (Long)", metadata.cloudPath.path)
		XCTAssertEqual(provider.lastModifiedDate, metadata.lastModifiedDate)
		XCTAssertEqual(0, metadata.size) // CryptorMock calculates a cleartext size of 0
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

	func testUploadFileWithLongNameWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat7ProviderDecorator = decorator
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false)
		}
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"], provider.createdFolders)
		XCTAssertEqual(Data("\(String(repeating: "file4", count: 44)).c9r".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s"])
		XCTAssertEqual(Data("ciphertext4".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r"])
		XCTAssertEqual("/File 4 (Long)", metadata.cloudPath.path)
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
}
