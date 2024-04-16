//
//  VaultFormat6CloudProviderMockTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
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

	func testVaultRootContainsFiles() async throws {
		let provider = VaultFormat6CloudProviderMock()
		let cloudItemList = try await provider.fetchItemList(forFolderAt: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"), withPageToken: nil).async()
		XCTAssertEqual(6, cloudItemList.items.count)
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "0dir1" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file1" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "file2" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng" }))
	}

	func testDir1FileContainsDirId() async throws {
		let provider = VaultFormat6CloudProviderMock()
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let metadata = try await provider.fetchItemMetadata(at: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1")).async()
		XCTAssertEqual(.file, metadata.itemType)
		try await provider.downloadFile(from: metadata.cloudPath, to: localURL).async()
		let downloadedContents = try Data(contentsOf: localURL)
		XCTAssertEqual("dir1-id".data(using: .utf8), downloadedContents)
	}
}
