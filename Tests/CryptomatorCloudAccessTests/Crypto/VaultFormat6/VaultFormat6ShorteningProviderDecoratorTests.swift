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

	override func testFetchItemListForRootDir() {
		let expectation = XCTestExpectation(description: "fetchItemList for root dir")
		decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).then { itemList in
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
		decorator.fetchItemMetadata(at: CloudPath("/Directory 3 (Long)/File 6 (Long)")).then { metadata in
			XCTAssertEqual("File 6 (Long)", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/Directory 3 (Long)/File 6 (Long)", metadata.cloudPath.path)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListForSubDirWithLongName() {
		let expectation = XCTestExpectation(description: "fetchItemList for sub dir with long name")
		decorator.fetchItemList(forFolderAt: CloudPath("/Directory 3 (Long)"), withPageToken: nil).then { itemList in
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
		decorator.downloadFile(from: CloudPath("/File 4 (Long)"), to: localURL).then {
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
		decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false).then { metadata in
			XCTAssertEqual(3, self.provider.createdFolders.count)
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m/2Q"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m/2Q/OD"))
			XCTAssertEqual(2, self.provider.createdFiles.count)
			XCTAssertEqual("ciphertext4".data(using: .utf8), self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
			XCTAssertEqual(String(repeating: "file4", count: 26).data(using: .utf8), self.provider.createdFiles["pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
			XCTAssertEqual("File 4 (Long)", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/File 4 (Long)", metadata.cloudPath.path)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolderWithLongName() {
		let expectation = XCTestExpectation(description: "createFolder with long name")
		decorator.createFolder(at: CloudPath("/Directory 3 (Long)")).then {
			XCTAssertEqual(5, self.provider.createdFolders.count)
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m/DL"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m/DL/2X"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/99"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
			XCTAssertEqual(2, self.provider.createdFiles.count)
			XCTAssertNotNil(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
			XCTAssertEqual("0\(String(repeating: "dir3", count: 33))".data(using: .utf8), self.provider.createdFiles["pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFileWithLongName() {
		let expectation = XCTestExpectation(description: "deleteFile with long name")
		decorator.deleteFile(at: CloudPath("/Directory 3 (Long)/File 6 (Long)")).then {
			XCTAssertEqual(1, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFolderWithLongName() {
		let expectation = XCTestExpectation(description: "deleteFolder with long name")
		decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)")).then {
			XCTAssertEqual(3, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"))
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"))
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFileFromShortToLongName() {
		let expectation = XCTestExpectation(description: "moveFile from short to long name")
		decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/File 4 (Long)")).then {
			XCTAssertEqual(3, self.provider.createdFolders.count)
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m/2Q"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m/2Q/OD"))
			XCTAssertEqual(1, self.provider.createdFiles.count)
			XCTAssertEqual(String(repeating: "file4", count: 26).data(using: .utf8), self.provider.createdFiles["pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng", self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1"])
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFileFromLongToShortName() {
		let expectation = XCTestExpectation(description: "moveFile from long to short name")
		decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 1")).then {
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1", self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFileFromLongToLongName() {
		let expectation = XCTestExpectation(description: "moveFile from long to long name")
		decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)")).then {
			XCTAssertEqual(3, self.provider.createdFolders.count)
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m/CI"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m/CI/VV"))
			XCTAssertEqual(1, self.provider.createdFiles.count)
			XCTAssertEqual(String(repeating: "file5", count: 26).data(using: .utf8), self.provider.createdFiles["pathToVault/m/CI/VV/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng"])
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng", self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFolderFromShortToLongName() {
		let expectation = XCTestExpectation(description: "moveFolder from short to long name")
		decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 3 (Long)")).then {
			XCTAssertEqual(3, self.provider.createdFolders.count)
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m/DL"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/m/DL/2X"))
			XCTAssertEqual(1, self.provider.createdFiles.count)
			XCTAssertEqual("0\(String(repeating: "dir3", count: 33))".data(using: .utf8), self.provider.createdFiles["pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng", self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"])
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFolderFromLongToShortName() {
		let expectation = XCTestExpectation(description: "moveFolder from long to short name")
		decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1")).then {
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1", self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}
}
