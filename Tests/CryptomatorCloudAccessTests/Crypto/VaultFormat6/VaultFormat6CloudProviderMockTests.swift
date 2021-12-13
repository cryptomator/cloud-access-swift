//
//  VaultFormat6CloudProviderMockTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Promises
import XCTest

class VaultFormat6CloudProviderMockTests: XCTestCase {
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
		let provider = VaultFormat6CloudProviderMock()
		provider.fetchItemList(forFolderAt: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"), withPageToken: nil).then { cloudItemList in
			XCTAssertEqual(6, cloudItemList.items.count)
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "0dir1" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file1" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file2" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng" }))
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
