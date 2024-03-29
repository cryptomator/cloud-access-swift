//
//  VaultFormat7ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
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

class VaultFormat7ProviderDecoratorTests: XCTestCase {
	let vaultPath = CloudPath("pathToVault")
	let cryptor = VaultFormat7CryptorMock(masterkey: Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32)))
	var tmpDirURL: URL!
	var provider: VaultFormat7CloudProviderMock!
	var decorator: VaultFormat7ProviderDecorator!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		provider = VaultFormat7CloudProviderMock()
		decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
	}

	override func tearDownWithError() throws {
		decorator = nil
		provider = nil
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() {
		let expectation = XCTestExpectation(description: "fetchItemMetadata")
		decorator.fetchItemMetadata(at: CloudPath("/Directory 1/File 3")).then { metadata in
			XCTAssertEqual("File 3", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/Directory 1/File 3", metadata.cloudPath.path)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListForRootDir() {
		let expectation = XCTestExpectation(description: "fetchItemList for root dir")
		decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).then { itemList in
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
		decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1"), withPageToken: nil).then { itemList in
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
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			print("\(progress.localizedDescription ?? "") (\(progress.localizedAdditionalDescription ?? ""))")
		}
		progress.becomeCurrent(withPendingUnitCount: 1)
		decorator.downloadFile(from: CloudPath("/File 1"), to: localURL).then {
			let cleartext = try String(contentsOf: localURL, encoding: .utf8)
			XCTAssertEqual("cleartext1", cleartext)
			XCTAssertTrue(progress.completedUnitCount >= progress.totalUnitCount)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			progressObserver.invalidate()
			expectation.fulfill()
		}
		progress.resignCurrent()
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFile() throws {
		let expectation = XCTestExpectation(description: "uploadFile")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
		let progress = Progress(totalUnitCount: 1)
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			print("\(progress.localizedDescription ?? "") (\(progress.localizedAdditionalDescription ?? ""))")
		}
		progress.becomeCurrent(withPendingUnitCount: 1)
		decorator.uploadFile(from: localURL, to: CloudPath("/File 1"), replaceExisting: false).then { metadata in
			XCTAssertEqual(1, self.provider.createdFiles.count)
			XCTAssertEqual("ciphertext1".data(using: .utf8), self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"])
			XCTAssertEqual("File 1", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/File 1", metadata.cloudPath.path)
			XCTAssertTrue(progress.completedUnitCount >= progress.totalUnitCount)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			progressObserver.invalidate()
			expectation.fulfill()
		}
		progress.resignCurrent()
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolder() {
		let expectation = XCTestExpectation(description: "createFolder")
		decorator.createFolder(at: CloudPath("/Directory 1")).then {
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

	func testDeleteFile() {
		let expectation = XCTestExpectation(description: "deleteFile")
		decorator.deleteFile(at: CloudPath("/Directory 1/File 3")).then {
			XCTAssertEqual(1, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFolder() {
		let expectation = XCTestExpectation(description: "deleteFolder")
		decorator.deleteFolder(at: CloudPath("/Directory 1")).then {
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

	func testDeleteFolderWithMissingDirFile() throws {
		let expectation = XCTestExpectation(description: "deleteFolder")
		// pathToVault
		// └─Directory 1
		//   ├─ Directory 2
		//   └─ File 3
		let folders: Set = [
			"pathToVault",
			"pathToVault/d",
			"pathToVault/d/00",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r",
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r",
			"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
		]
		let files = [
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r/dir.c9r": "dir2-id".data(using: .utf8)!,
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r": "ciphertext3".data(using: .utf8)!
		]
		let provider = VaultFormat7CloudProviderMock(folders: folders, files: files)
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		decorator.deleteFolder(at: CloudPath("/Directory 1")).then {
			XCTAssertEqual(1, provider.deleted.count)
			XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFolderWithBrokenFolder() throws {
		let expectation = XCTestExpectation(description: "deleteFolder")
		let folders: Set = [
			"pathToVault",
			"pathToVault/d",
			"pathToVault/d/00",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"
		]
		let files = [
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r": "dir1-id".data(using: .utf8)!
		]
		let provider = VaultFormat7CloudProviderMock(folders: folders, files: files)
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
		decorator.deleteFolder(at: CloudPath("/Directory 1")).then {
			XCTAssertEqual(1, provider.deleted.count)
			XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFile() {
		let expectation = XCTestExpectation(description: "moveFile")
		decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/Directory 1/File 2")).then {
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertEqual("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file2.c9r", self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"])
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}
}
