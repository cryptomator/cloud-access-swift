//
//  VaultFormat7CloudProviderMockTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultFormat7CloudProviderMockTests: XCTestCase {
	var tmpDirURL: URL!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testVaultRootContainsFiles() {
		let expectation = XCTestExpectation(description: "vaultRootContainsFiles")
		let provider = VaultFormat7CloudProviderMock()
		provider.fetchItemList(forFolderAt: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"), withPageToken: nil).then { cloudItemList in
			XCTAssertEqual(6, cloudItemList.items.count)
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "dir1.c9r" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file1.c9r" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file2.c9r" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDir1FileContainsDirId() {
		let expectation = XCTestExpectation(description: "dir1FileContainsDirId")
		let provider = VaultFormat7CloudProviderMock()
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		provider.fetchItemMetadata(at: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r")).then { metadata -> Promise<Void> in
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
