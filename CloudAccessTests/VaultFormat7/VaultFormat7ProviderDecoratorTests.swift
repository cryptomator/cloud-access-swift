//
//  VaultFormat7ProviderDecoratorTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
@testable import CloudAccess
@testable import CryptomatorCryptoLib

class VaultFormat7ProviderDecoratorTests: XCTestCase {
	let vaultURL = URL(fileURLWithPath: "pathToVault")
	let cryptor = CryptorMock(masterkey: Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32), version: 7))
	var tmpDirURL: URL!
	var provider: CloudProviderMock!
	var decorator: VaultFormat7ProviderDecorator!

	override func setUpWithError() throws {
		tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		provider = CloudProviderMock()
		decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultURL: vaultURL, cryptor: cryptor)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() {
		let expectation = XCTestExpectation(description: "fetchItemMetadata")
		decorator.fetchItemMetadata(at: URL(fileURLWithPath: "/Directory 1/File 3")).then { metadata in
			XCTAssertEqual("File 3", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/Directory 1/File 3", metadata.remoteURL.path)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListForRootDir() {
		let expectation = XCTestExpectation(description: "fetchItemList for root dir")
		decorator.fetchItemList(forFolderAt: URL(fileURLWithPath: "/", isDirectory: true), withPageToken: nil).then { itemList in
			XCTAssertEqual(3, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 1" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 2" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 1" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListForSubDir() {
		let expectation = XCTestExpectation(description: "fetchItemList for sub dir")
		decorator.fetchItemList(forFolderAt: URL(fileURLWithPath: "/Directory 1", isDirectory: true), withPageToken: nil).then { itemList in
			XCTAssertEqual(2, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 3" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 2" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFile() {
		let expectation = XCTestExpectation(description: "downloadFile")
		let localURL = tmpDirURL.appendingPathComponent("File 1")
		decorator.downloadFile(from: URL(fileURLWithPath: "/File 1"), to: localURL, progress: nil).then {
			let cleartext = try String(contentsOf: localURL, encoding: .utf8)
			XCTAssertEqual("cleartext1", cleartext)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFile() throws {
		let expectation = XCTestExpectation(description: "uploadFile")
		let localURL = tmpDirURL.appendingPathComponent("file1.c9r")
		try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
		decorator.uploadFile(from: localURL, to: URL(fileURLWithPath: "/File 1"), replaceExisting: false, progress: nil).then { metadata in
			XCTAssertEqual(1, self.provider.createdFiles.count)
			XCTAssertTrue(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"] == "ciphertext1".data(using: .utf8))
			XCTAssertEqual("File 1", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/File 1", metadata.remoteURL.path)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolder() {
		let expectation = XCTestExpectation(description: "createFolder")
		decorator.createFolder(at: URL(fileURLWithPath: "/Directory 1", isDirectory: true)).then {
			XCTAssertEqual(3, self.provider.createdFolders.count)
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/99"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
			XCTAssertEqual(1, self.provider.createdFiles.count)
			XCTAssertNotNil(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r"])
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteDirectoryRecursively() {
		let expectation = XCTestExpectation(description: "deleteItem on folder")
		decorator.deleteItem(at: URL(fileURLWithPath: "/Directory 1", isDirectory: true)).then {
			XCTAssertEqual(3, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFile() {
		let expectation = XCTestExpectation(description: "deleteItem on file")
		decorator.deleteItem(at: URL(fileURLWithPath: "/Directory 1/File 3")).then {
			XCTAssertEqual(1, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItem() {
		let expectation = XCTestExpectation(description: "moveItem")
		decorator.moveItem(from: URL(fileURLWithPath: "/File 1"), to: URL(fileURLWithPath: "/Directory 1/File 2")).then {
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertTrue(self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"] == "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file2.c9r")
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}
}
