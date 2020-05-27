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
	let pathToVault = URL(fileURLWithPath: "pathToVault")
	let cryptor = CryptorMock(masterKey: Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32), version: 7))

	func testFetchItemListForRootDir() throws {
		let expectation = XCTestExpectation(description: "fetchItemList")
		let provider = CloudProviderMock()
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, remotePathToVault: pathToVault, cryptor: cryptor)

		decorator.fetchItemList(forFolderAt: URL(fileURLWithPath: "/"), withPageToken: nil).then { itemList in
			XCTAssertEqual(3, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 1" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 2" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 1" }))
		}.catch { error in
			XCTFail("Promise rejected: \(error)")
		}.always {
			expectation.fulfill()
		}

		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListForSubDir() throws {
		let expectation = XCTestExpectation(description: "fetchItemList")
		let provider = CloudProviderMock()
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, remotePathToVault: pathToVault, cryptor: cryptor)

		decorator.fetchItemList(forFolderAt: URL(fileURLWithPath: "/Directory 1"), withPageToken: nil).then { itemList in
			XCTAssertEqual(2, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 3" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 2" }))
		}.catch { error in
			XCTFail("Promise rejected: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemMetadata() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata")
		let provider = CloudProviderMock()
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, remotePathToVault: pathToVault, cryptor: cryptor)

		decorator.fetchItemMetadata(at: URL(fileURLWithPath: "/Directory 1/File 3")).then { metadata in
			XCTAssertEqual("File 3", metadata.name)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual("/Directory 1/File 3", metadata.remoteURL.path)
		}.catch { error in
			XCTFail("Promise rejected: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteDirectoryRecursively() throws {
		let expectation = XCTestExpectation(description: "deleteItem")
		let provider = CloudProviderMock()
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, remotePathToVault: pathToVault, cryptor: cryptor)

		decorator.deleteItem(at: URL(fileURLWithPath: "/Directory 1", isDirectory: true)).then {
			XCTAssertEqual(3, provider.deleted.count)
			XCTAssertTrue(provider.deleted.contains("pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"))
			XCTAssertTrue(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"))
			XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		}.catch { error in
			XCTFail("Promise rejected: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFile() throws {
		let expectation = XCTestExpectation(description: "deleteItem")
		let provider = CloudProviderMock()
		let decorator = try VaultFormat7ProviderDecorator(delegate: provider, remotePathToVault: pathToVault, cryptor: cryptor)

		decorator.deleteItem(at: URL(fileURLWithPath: "/Directory 1/File 3")).then {
			XCTAssertEqual(1, provider.deleted.count)
			XCTAssertTrue(provider.deleted.contains("pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r"))
		}.catch { error in
			XCTFail("Promise rejected: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}
}
