//
//  VaultFormat7ShorteningProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import Promises
import XCTest
@testable import CryptomatorCryptoLib

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

	override func testFetchItemListForRootDir() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).async()
		XCTAssertEqual(6, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 1" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 3 (Long)" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 1" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 2" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 4 (Long)" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 5 (Long)" }))
	}

	func testFetchItemMetadataWithLongName() async throws {
		let metadata = try await decorator.fetchItemMetadata(at: CloudPath("/Directory 3 (Long)/File 6 (Long)")).async()
		XCTAssertEqual("File 6 (Long)", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/Directory 3 (Long)/File 6 (Long)", metadata.cloudPath.path)
	}

	func testFetchItemListForSubDirWithLongName() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 3 (Long)"), withPageToken: nil).async()
		XCTAssertEqual(2, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 6 (Long)" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 4 (Long)" }))
	}

	func testDownloadFileWithLongName() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try await decorator.downloadFile(from: CloudPath("/File 4 (Long)"), to: localURL).async()
		let cleartext = try String(contentsOf: localURL, encoding: .utf8)
		XCTAssertEqual("cleartext4", cleartext)
	}

	func testUploadFileWithLongName() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false).async()
		XCTAssertEqual(2, provider.createdFiles.count)
		XCTAssertEqual("ciphertext4".data(using: .utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r"])
		XCTAssertEqual("\(String(repeating: "file4", count: 44)).c9r".data(using: .utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s"])
		XCTAssertEqual("File 4 (Long)", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 4 (Long)", metadata.cloudPath.path)
	}

	func testCreateFolderWithLongName() async throws {
		try await decorator.createFolder(at: CloudPath("/Directory 3 (Long)")).async()
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
		XCTAssertEqual(2, provider.createdFiles.count)
		XCTAssertNotNil(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/dir.c9r"])
		XCTAssertEqual("\(String(repeating: "dir3", count: 55)).c9r".data(using: .utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"])
	}

	func testDeleteFileWithLongName() async throws {
		try await decorator.deleteFile(at: CloudPath("/Directory 3 (Long)/File 6 (Long)")).async()
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s"))
	}

	func testDeleteFolderWithLongName() async throws {
		try await decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)")).async()
		XCTAssertEqual(3, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"))
	}

	func testMoveFileFromShortToLongName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/File 4 (Long)")).async()
		XCTAssertEqual(1, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual("\(String(repeating: "file4", count: 44)).c9r".data(using: .utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s"])
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"])
	}

	func testMoveFileFromLongToShortName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 1")).async()
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r"])
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"))
	}

	func testMoveFileFromLongToLongName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)")).async()
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"])
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual("\(String(repeating: "file5", count: 44)).c9r".data(using: .utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/name.c9s"])
	}

	func testMoveFolderFromShortToLongName() async throws {
		try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 3 (Long)")).async()
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"])
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual("\(String(repeating: "dir3", count: 55)).c9r".data(using: .utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"])
	}

	func testMoveFolderFromLongToShortName() async throws {
		try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1")).async()
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"])
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/name.c9s"))
	}
}
