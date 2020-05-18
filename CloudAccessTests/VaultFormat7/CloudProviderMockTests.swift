//
//  CloudProviderMockTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
@testable import CloudAccess

class CloudProviderMockTests: XCTestCase {
	var tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

	override func setUp() {
		tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
		do {
			try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
		} catch {
			XCTFail("Error in setUp: \(error)")
		}
	}

	override func tearDown() {
		do {
			try FileManager.default.removeItem(at: tmpDir)
		} catch {
			XCTFail("Error in teardown: \(error)")
		}
	}

	func testVaultRootContainsFiles() {
		let expectation = XCTestExpectation(description: "fetchItemList")
		let provider = CloudProviderMock()
		let url = URL(fileURLWithPath: "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
		provider.fetchItemList(forFolderAt: url, withPageToken: nil).then { cloudItemList in
			XCTAssertEqual(3, cloudItemList.items.count)
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file1.c9r" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file2.c9r" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "dir1.c9r" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDir1FileContainsDirId() {
		let expectation = XCTestExpectation(description: "fetchItemMetadata")
		let provider = CloudProviderMock()
		let remoteURL = URL(fileURLWithPath: "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r")
		let localURL = tmpDir.appendingPathComponent("dir.c9r")
		provider.fetchItemMetadata(at: remoteURL).then { metadata -> Promise<CloudItemMetadata> in
			XCTAssertEqual(.file, metadata.itemType)
			return provider.downloadFile(from: metadata.remoteURL, to: localURL, progress: nil)
		}.then { _ in
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
