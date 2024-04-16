//
//  VaultFormat6ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
@testable import CryptomatorCryptoLib

class VaultFormat6ProviderDecoratorTests: XCTestCase {
	let vaultPath = CloudPath("pathToVault")
	let cryptor = VaultFormat6CryptorMock(masterkey: Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32)))
	var tmpDirURL: URL!
	var provider: VaultFormat6CloudProviderMock!
	var decorator: VaultFormat6ProviderDecorator!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		provider = VaultFormat6CloudProviderMock()
		decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
	}

	override func tearDownWithError() throws {
		decorator = nil
		provider = nil
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() async throws {
		let metadata = try await decorator.fetchItemMetadata(at: CloudPath("/Directory 1/File 3")).async()
		XCTAssertEqual("File 3", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/Directory 1/File 3", metadata.cloudPath.path)
	}

	func testFetchItemListForRootDir() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).async()
		XCTAssertEqual(3, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 1" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 2" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 1" }))
	}

	func testFetchItemListForSubDir() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1"), withPageToken: nil).async()
		XCTAssertEqual(2, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 3" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 2" }))
	}

	// TODO: Re-enable progress testing if you know how to handle implicit progress reporting in an async method
	func testDownloadFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
//		let progress = Progress(totalUnitCount: 1)
//		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
//			print("\(progress.localizedDescription ?? "") (\(progress.localizedAdditionalDescription ?? ""))")
//		}
//		progress.becomeCurrent(withPendingUnitCount: 1)
		try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL).async()
		let cleartext = try String(contentsOf: localURL, encoding: .utf8)
		XCTAssertEqual("cleartext1", cleartext)
//		XCTAssertTrue(progress.completedUnitCount >= progress.totalUnitCount)
//		progressObserver.invalidate()
//		progress.resignCurrent()
	}

	// TODO: Re-enable progress testing if you know how to handle implicit progress reporting in an async method
	func testUploadFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
//		let progress = Progress(totalUnitCount: 1)
//		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
//			print("\(progress.localizedDescription ?? "") (\(progress.localizedAdditionalDescription ?? ""))")
//		}
//		progress.becomeCurrent(withPendingUnitCount: 1)
		let metadata = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 1"), replaceExisting: false).async()
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual("ciphertext1".data(using: .utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1"])
		XCTAssertEqual("File 1", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 1", metadata.cloudPath.path)
//		XCTAssertTrue(progress.completedUnitCount >= progress.totalUnitCount)
//		progressObserver.invalidate()
//		progress.resignCurrent()
	}

	func testCreateFolder() async throws {
		try await decorator.createFolder(at: CloudPath("/Directory 1")).async()
		XCTAssertEqual(2, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertNotNil(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"])
	}

	func testDeleteFile() async throws {
		try await decorator.deleteFile(at: CloudPath("/Directory 1/File 3")).async()
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3"))
	}

	func testDeleteFolder() async throws {
		try await decorator.deleteFolder(at: CloudPath("/Directory 1")).async()
		XCTAssertEqual(3, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"))
	}

	func testDeleteFolderWithMissingDirFile() async throws {
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
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": "dir2-id".data(using: .utf8)!,
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3": "ciphertext3".data(using: .utf8)!
		]

		let provider = VaultFormat6CloudProviderMock(folders: folders, files: files)
		let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		try await decorator.deleteFolder(at: CloudPath("/Directory 1")).async()
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"))
	}

	func testDeleteFolderWithBrokenFolder() async throws {
		let folders: Set = [
			"pathToVault",
			"pathToVault/d",
			"pathToVault/d/00",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
		]
		let files = [
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1": "dir1-id".data(using: .utf8)!
		]
		let provider = VaultFormat6CloudProviderMock(folders: folders, files: files)
		let decorator = try VaultFormat6ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		try await decorator.deleteFolder(at: CloudPath("/Directory 1")).async()
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"))
	}

	func testMoveFile() async throws {
		try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/Directory 1/File 2")).async()
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file2", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1"])
	}
}
