//
//  VaultFormat7ProviderDecoratorTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
@testable import CloudAccess
@testable import CryptomatorCryptoLib
@testable import Promises

class VaultFormat7ProviderDecoratorTests: XCTestCase {
	let vaultURL = URL(fileURLWithPath: "pathToVault")
	let cryptor = CryptorMock(masterkey: Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32), version: 7))
	var provider: CloudProviderMock!
	var decorator: VaultFormat7ProviderDecorator!

	override func setUpWithError() throws {
		provider = CloudProviderMock()
		decorator = try VaultFormat7ProviderDecorator(delegate: provider, remoteVaultURL: vaultURL, cryptor: cryptor)
	}

	func testFetchItemMetadata() throws {
		decorator.fetchItemMetadata(at: URL(fileURLWithPath: "/Directory 1/File 3")).then { metadata in
			XCTAssertEqual("File 3", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/Directory 1/File 3", metadata.remoteURL.path)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}
		XCTAssertTrue(waitForPromises(timeout: 1.0))
	}

	func testFetchItemListForRootDir() throws {
		decorator.fetchItemList(forFolderAt: URL(fileURLWithPath: "/", isDirectory: true), withPageToken: nil).then { itemList in
			XCTAssertEqual(3, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 1" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 2" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 1" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}
		XCTAssertTrue(waitForPromises(timeout: 1.0))
	}

	func testFetchItemListForSubDir() throws {
		decorator.fetchItemList(forFolderAt: URL(fileURLWithPath: "/Directory 1", isDirectory: true), withPageToken: nil).then { itemList in
			XCTAssertEqual(2, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 3" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 2" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}
		XCTAssertTrue(waitForPromises(timeout: 1.0))
	}

	func testDeleteDirectoryRecursively() throws {
		decorator.deleteItem(at: URL(fileURLWithPath: "/Directory 1", isDirectory: true)).then {
			XCTAssertEqual(3, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}
		XCTAssertTrue(waitForPromises(timeout: 1.0))
	}

	func testDeleteFile() throws {
		decorator.deleteItem(at: URL(fileURLWithPath: "/Directory 1/File 3")).then {
			XCTAssertEqual(1, self.provider.deleted.count)
			XCTAssertTrue(self.provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}
		XCTAssertTrue(waitForPromises(timeout: 1.0))
	}

	func testMoveItem() throws {
		decorator.moveItem(from: URL(fileURLWithPath: "/File 1"), to: URL(fileURLWithPath: "/Directory 1/File 2")).then {
			XCTAssertEqual(1, self.provider.moved.count)
			XCTAssertTrue(self.provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r"] == "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file2.c9r")
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}
		XCTAssertTrue(waitForPromises(timeout: 1.0))
	}
}
