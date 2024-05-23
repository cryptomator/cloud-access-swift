//
//  VaultFormat6ShorteningProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.09.20.
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

class VaultFormat6ShorteningProviderDecoratorTests: VaultFormat6ProviderDecoratorTests {
	var shorteningDecorator: VaultFormat6ShorteningProviderDecorator!

	override func setUpWithError() throws {
		try super.setUpWithError()
		shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		decorator = try VaultFormat6ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
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
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/2Q"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/2Q/OD"))
		XCTAssertEqual(2, provider.createdFiles.count)
		XCTAssertEqual(Data("ciphertext4".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
		XCTAssertEqual(String(repeating: "file4", count: 26).data(using: .utf8), provider.createdFiles["pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
		XCTAssertEqual("File 4 (Long)", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 4 (Long)", metadata.cloudPath.path)
	}

	func testCreateFolderWithLongName() async throws {
		try await decorator.createFolder(at: CloudPath("/Directory 3 (Long)")).async()
		XCTAssertEqual(5, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/DL"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/DL/2X"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
		XCTAssertEqual(2, provider.createdFiles.count)
		XCTAssertNotNil(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
		XCTAssertEqual(Data("0\(String(repeating: "dir3", count: 33))".utf8), provider.createdFiles["pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
	}

	func testDeleteFileWithLongName() async throws {
		try await decorator.deleteFile(at: CloudPath("/Directory 3 (Long)/File 6 (Long)")).async()
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng"))
	}

	func testDeleteFolderWithLongName() async throws {
		try await decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)")).async()
		XCTAssertEqual(3, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"))
	}

	func testMoveFileFromShortToLongName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/File 4 (Long)")).async()
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/2Q"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/2Q/OD"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual(String(repeating: "file4", count: 26).data(using: .utf8), provider.createdFiles["pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1"])
	}

	func testMoveFileFromLongToShortName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 1")).async()
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
	}

	func testMoveFileFromLongToLongName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)")).async()
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/CI"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/CI/VV"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual(String(repeating: "file5", count: 26).data(using: .utf8), provider.createdFiles["pathToVault/m/CI/VV/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng"])
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
	}

	func testMoveFolderFromShortToLongName() async throws {
		try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 3 (Long)")).async()
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/DL"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/DL/2X"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual(Data("0\(String(repeating: "dir3", count: 33))".utf8), provider.createdFiles["pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"])
	}

	func testMoveFolderFromLongToShortName() async throws {
		try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1")).async()
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
	}
}
