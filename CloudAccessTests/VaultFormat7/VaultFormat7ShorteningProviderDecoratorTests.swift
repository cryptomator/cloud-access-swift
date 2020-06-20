//
//  VaultFormat7ShorteningProviderDecoratorTests.swift
//  CloudAccessTests
//
//  Created by Tobias Hagemann on 19.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
@testable import CloudAccess
@testable import CryptomatorCryptoLib

class VaultFormat7ShorteningProviderDecoratorTests: VaultFormat7ProviderDecoratorTests {
	var shorteningDecorator: VaultFormat7ShorteningProviderDecorator!

	override func setUpWithError() throws {
		try super.setUpWithError()
		shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultURL: vaultURL)
		decorator = try VaultFormat7ProviderDecorator(delegate: shorteningDecorator, vaultURL: vaultURL, cryptor: cryptor)
	}

	override func testFetchItemListForRootDir() {
		let expectation = XCTestExpectation(description: "fetchItemList for root dir")
		decorator.fetchItemList(forFolderAt: URL(fileURLWithPath: "/", isDirectory: true), withPageToken: nil).then { itemList in
			XCTAssertEqual(4, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 1" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 2" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 1" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Long Name Directory" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemMetadataWithLongName() {
		let expectation = XCTestExpectation(description: "fetchItemMetadata with long name")
		decorator.fetchItemMetadata(at: URL(fileURLWithPath: "/Long Name Directory/Long Name File", isDirectory: false)).then { metadata in
			XCTAssertEqual("Long Name File", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/Long Name Directory/Long Name File", metadata.remoteURL.path)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListWithLongName() {
		let expectation = XCTestExpectation(description: "fetchItemList with long name")
		decorator.fetchItemList(forFolderAt: URL(fileURLWithPath: "/Long Name Directory", isDirectory: true), withPageToken: nil).then { itemList in
			XCTAssertEqual(1, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Long Name File" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFileWithLongName() {
		let expectation = XCTestExpectation(description: "downloadFile with long name")
		let localURL = tmpDirURL.appendingPathComponent("File 1", isDirectory: false)
		decorator.downloadFile(from: URL(fileURLWithPath: "/Long Name Directory/Long Name File", isDirectory: false), to: localURL, progress: nil).then {
			let cleartext = try String(contentsOf: localURL, encoding: .utf8)
			XCTAssertEqual("cleartext4", cleartext)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithLongName() throws {
		let expectation = XCTestExpectation(description: "uploadFile with long name")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		decorator.uploadFile(from: localURL, to: URL(fileURLWithPath: "/Long Name Directory/Long Name File"), replaceExisting: false, progress: nil).then { metadata in
			XCTAssertEqual(2, self.provider.createdFiles.count)
			XCTAssertTrue(self.provider.createdFiles["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/zJnBY0kkM89vsN5Rl7y-p1dnueo=.c9s/contents.c9r"] == "ciphertext4".data(using: .utf8))
			XCTAssertTrue(self.provider.createdFiles["pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/zJnBY0kkM89vsN5Rl7y-p1dnueo=.c9s/name.c9s"] == "\(String(repeating: "b", count: 217)).c9r".data(using: .utf8))
			XCTAssertEqual("Long Name File", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/Long Name Directory/Long Name File", metadata.remoteURL.path)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolderWithLongName() {
		let expectation = XCTestExpectation(description: "createFolder with long name")
		decorator.createFolder(at: URL(fileURLWithPath: "/Long Name Directory", isDirectory: true)).then {
			XCTAssertEqual(3, self.provider.createdFolders.count)
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/99"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
			XCTAssertEqual(2, self.provider.createdFiles.count)
			XCTAssertNotNil(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r"])
			XCTAssertTrue(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/name.c9s"] == "\(String(repeating: "a", count: 217)).c9r".data(using: .utf8))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFolderWithLongName() {
		let expectation = XCTestExpectation(description: "deleteItem on folder with long name")
		decorator.deleteItem(at: URL(fileURLWithPath: "/Long Name Directory", isDirectory: true)).then {
			XCTAssertEqual(2, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"))
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFileWithLongName() {
		let expectation = XCTestExpectation(description: "deleteItem on file with long name")
		decorator.deleteItem(at: URL(fileURLWithPath: "/Long Name Directory/Long Name File")).then {
			XCTAssertEqual(1, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/zJnBY0kkM89vsN5Rl7y-p1dnueo=.c9s"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}
}
