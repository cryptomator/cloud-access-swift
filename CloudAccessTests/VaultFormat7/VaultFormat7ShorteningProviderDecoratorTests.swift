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
			XCTAssertEqual(6, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 1" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 3 (Long)" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 1" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 2" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 4 (Long)" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 5 (Long)" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemMetadataWithLongName() {
		let expectation = XCTestExpectation(description: "fetchItemMetadata with long name")
		decorator.fetchItemMetadata(at: URL(fileURLWithPath: "/Directory 3 (Long)/File 6 (Long)", isDirectory: false)).then { metadata in
			XCTAssertEqual("File 6 (Long)", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/Directory 3 (Long)/File 6 (Long)", metadata.remoteURL.path)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListForSubDirWithLongName() {
		let expectation = XCTestExpectation(description: "fetchItemList for sub dir with long name")
		decorator.fetchItemList(forFolderAt: URL(fileURLWithPath: "/Directory 3 (Long)", isDirectory: true), withPageToken: nil).then { itemList in
			XCTAssertEqual(2, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 6 (Long)" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 4 (Long)" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFileWithLongName() {
		let expectation = XCTestExpectation(description: "downloadFile with long name")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		decorator.downloadFile(from: URL(fileURLWithPath: "/File 4 (Long)", isDirectory: false), to: localURL, progress: nil).then {
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
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		decorator.uploadFile(from: localURL, to: URL(fileURLWithPath: "/File 4 (Long)", isDirectory: false), replaceExisting: false, progress: nil).then { metadata in
			XCTAssertEqual(2, self.provider.createdFiles.count)
			XCTAssertTrue(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r"] == "ciphertext4".data(using: .utf8))
			XCTAssertTrue(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s"] == "\(String(repeating: "file4", count: 44)).c9r".data(using: .utf8))
			XCTAssertEqual("File 4 (Long)", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/File 4 (Long)", metadata.remoteURL.path)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolderWithLongName() {
		let expectation = XCTestExpectation(description: "createFolder with long name")
		decorator.createFolder(at: URL(fileURLWithPath: "/Directory 3 (Long)", isDirectory: true)).then {
			XCTAssertEqual(3, self.provider.createdFolders.count)
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/99"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
			XCTAssertEqual(2, self.provider.createdFiles.count)
			XCTAssertNotNil(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/dir.c9r"])
			XCTAssertTrue(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"] == "\(String(repeating: "dir3", count: 55)).c9r".data(using: .utf8))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFolderWithLongName() {
		let expectation = XCTestExpectation(description: "deleteItem on folder with long name")
		decorator.deleteItem(at: URL(fileURLWithPath: "/Directory 3 (Long)", isDirectory: true)).then {
			XCTAssertEqual(3, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"))
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"))
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFileWithLongName() {
		let expectation = XCTestExpectation(description: "deleteItem on file with long name")
		decorator.deleteItem(at: URL(fileURLWithPath: "/Directory 3 (Long)/File 6 (Long)", isDirectory: false)).then {
			XCTAssertEqual(1, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFolderFromShortToLongName() {
		let expectation = XCTestExpectation(description: "moveItem on folder from short to long name")
		decorator.moveItem(from: URL(fileURLWithPath: "/Directory 1", isDirectory: true), to: URL(fileURLWithPath: "/Directory 3 (Long)", isDirectory: true)).then {
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertTrue(self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"] == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s")
			XCTAssertEqual(1, self.provider.createdFiles.count)
			XCTAssertTrue(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s"] == "\(String(repeating: "dir3", count: 55)).c9r".data(using: .utf8))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFileFromShortToLongName() {
		let expectation = XCTestExpectation(description: "moveItem on file from short to long name")
		decorator.moveItem(from: URL(fileURLWithPath: "/File 1", isDirectory: false), to: URL(fileURLWithPath: "/File 4 (Long)", isDirectory: false)).then {
			XCTAssertEqual(1, self.provider.createdFolders.count)
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"))
			XCTAssertEqual(1, self.provider.createdFiles.count)
			XCTAssertTrue(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s"] == "\(String(repeating: "file4", count: 44)).c9r".data(using: .utf8))
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertTrue(self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"] == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r")
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFolderFromLongToShortName() {
		let expectation = XCTestExpectation(description: "moveItem on folder from long to short name")
		decorator.moveItem(from: URL(fileURLWithPath: "/Directory 3 (Long)", isDirectory: true), to: URL(fileURLWithPath: "/Directory 1", isDirectory: true)).then {
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertTrue(self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s"] == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r")
			XCTAssertEqual(1, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/name.c9s"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFileFromLongToShortName() {
		let expectation = XCTestExpectation(description: "moveItem on file from long to short name")
		decorator.moveItem(from: URL(fileURLWithPath: "/File 4 (Long)", isDirectory: false), to: URL(fileURLWithPath: "/File 1", isDirectory: false)).then {
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertTrue(self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r"] == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r")
			XCTAssertEqual(1, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFileFromLongToLongName() {
		let expectation = XCTestExpectation(description: "moveItem on file from long to long name")
		decorator.moveItem(from: URL(fileURLWithPath: "/File 4 (Long)", isDirectory: false), to: URL(fileURLWithPath: "/File 5 (Long)", isDirectory: false)).then {
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertTrue(self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s"] == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s")
			XCTAssertEqual(1, self.provider.createdFiles.count)
			XCTAssertTrue(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/name.c9s"] == "\(String(repeating: "file5", count: 44)).c9r".data(using: .utf8))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}
}
