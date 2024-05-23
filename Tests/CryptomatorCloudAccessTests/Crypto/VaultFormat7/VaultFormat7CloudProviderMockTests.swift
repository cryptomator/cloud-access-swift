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

	func testVaultRootContainsFiles() async throws {
		let provider = VaultFormat7CloudProviderMock()
		let cloudItemList = try await provider.fetchItemList(forFolderAt: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"), withPageToken: nil).async()
		XCTAssertEqual(6, cloudItemList.items.count)
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "dir1.c9r" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file1.c9r" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file2.c9r" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s" }))
	}

	func testDir1FileContainsDirId() async throws {
		let provider = VaultFormat7CloudProviderMock()
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let metadata = try await provider.fetchItemMetadata(at: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r")).async()
		XCTAssertEqual(.file, metadata.itemType)
		try await provider.downloadFile(from: metadata.cloudPath, to: localURL).async()
		let downloadedContents = try Data(contentsOf: localURL)
		XCTAssertEqual(Data("dir1-id".utf8), downloadedContents)
	}
}
