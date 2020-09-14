//
//  VaultFormat6CloudProviderMockTests.swift
//  CloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
@testable import CloudAccess

class VaultFormat6CloudProviderMockTests: XCTestCase {
	var tmpDirURL: URL!

	override func setUpWithError() throws {
		tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testVaultRootContainsFiles() {
		let expectation = XCTestExpectation(description: "vaultRootContainsFiles")
		let provider = VaultFormat6CloudProviderMock()
		provider.fetchItemList(forFolderAt: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/"), withPageToken: nil).then { cloudItemList in
			XCTAssertEqual(3, cloudItemList.items.count)
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "0dir1" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file1" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file2" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDir1FileContainsDirId() {
		let expectation = XCTestExpectation(description: "dir1FileContainsDirId")
		let provider = VaultFormat6CloudProviderMock()
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		provider.fetchItemMetadata(at: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1")).then { metadata -> Promise<Void> in
			XCTAssertEqual(.file, metadata.itemType)
			return provider.downloadFile(from: metadata.cloudPath, to: localURL)
		}.then {
			let downloadedContents = try Data(contentsOf: localURL)
			XCTAssertEqual("dir1-id".data(using: .utf8), downloadedContents)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}
}