//
//  CloudProviderMockTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
@testable import CloudAccess
@testable import Promises

class CloudProviderMockTests: XCTestCase {
	var tmpDirURL: URL!

	override func setUpWithError() throws {
		tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testVaultRootContainsFiles() {
		let provider = CloudProviderMock()
		let url = URL(fileURLWithPath: "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", isDirectory: true)
		provider.fetchItemList(forFolderAt: url, withPageToken: nil).then { cloudItemList in
			XCTAssertEqual(3, cloudItemList.items.count)
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file1.c9r" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file2.c9r" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "dir1.c9r" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}
		XCTAssertTrue(waitForPromises(timeout: 1.0))
	}

	func testDir1FileContainsDirId() {
		let provider = CloudProviderMock()
		let remoteURL = URL(fileURLWithPath: "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r")
		let localURL = tmpDirURL.appendingPathComponent("dir.c9r")
		provider.fetchItemMetadata(at: remoteURL).then { metadata -> Promise<Void> in
			XCTAssertEqual(.file, metadata.itemType)
			return provider.downloadFile(from: metadata.remoteURL, to: localURL, progress: nil)
		}.then {
			let downloadedContents = try Data(contentsOf: localURL)
			XCTAssertEqual("dir1-id".data(using: .utf8), downloadedContents)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}
		XCTAssertTrue(waitForPromises(timeout: 1.0))
	}
}
