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

class VaultFormat7ShorteningProviderDecoratorTests: XCTestCase {
	let vaultURL = URL(fileURLWithPath: "pathToVault")
	let cryptor = CryptorMock(masterkey: Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32), version: 7))
	var tmpDirURL: URL!
	var provider: CloudProviderMock!
	var shorteningDecorator: VaultFormat7ShorteningProviderDecorator!
	var cryptoDecorator: VaultFormat7ProviderDecorator!

	override func setUpWithError() throws {
		tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		provider = CloudProviderMock()
		shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultURL: vaultURL)
		cryptoDecorator = try VaultFormat7ProviderDecorator(delegate: shorteningDecorator, vaultURL: vaultURL, cryptor: cryptor)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() {
		let expectation = XCTestExpectation(description: "fetchItemMetadata")
		cryptoDecorator.fetchItemMetadata(at: URL(fileURLWithPath: "/Long Name Directory/Long Name File", isDirectory: false)).then { metadata in
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

	func testFetchItemList() {
		let expectation = XCTestExpectation(description: "fetchItemList")
		cryptoDecorator.fetchItemList(forFolderAt: URL(fileURLWithPath: "/Long Name Directory", isDirectory: true), withPageToken: nil).then { itemList in
			XCTAssertEqual(1, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Long Name File" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}
}
