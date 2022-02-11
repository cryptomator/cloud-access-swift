//
//  GoogleDriveIdentifierCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 11.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class GoogleDriveIdentifierCacheTests: XCTestCase {
	var identifierCache: GoogleDriveIdentifierCache!

	override func setUpWithError() throws {
		identifierCache = try GoogleDriveIdentifierCache()
	}

	func testRootItemIsCachedAtStart() throws {
		let expectedRootItem = GoogleDriveItem(cloudPath: CloudPath("/"), identifier: "root", itemType: .folder, shortcut: nil)
		let rootItem = identifierCache.get(expectedRootItem.cloudPath)
		XCTAssertNotNil(rootItem)
		XCTAssertEqual(expectedRootItem, rootItem)
	}

	func testAddAndGetForFileCloudPath() throws {
		let itemToStore = GoogleDriveItem(cloudPath: CloudPath("/abc/test.txt"), identifier: "TestABC--1234@^", itemType: .file, shortcut: nil)
		try identifierCache.addOrUpdate(itemToStore)
		let retrievedItem = identifierCache.get(itemToStore.cloudPath)
		XCTAssertNotNil(retrievedItem)
		XCTAssertEqual(itemToStore, retrievedItem)
	}

	func testAddAndGetForFolderCloudPath() throws {
		let itemToStore = GoogleDriveItem(cloudPath: CloudPath("/abc/test--a-"), identifier: "TestABC--1234@^", itemType: .folder, shortcut: nil)
		try identifierCache.addOrUpdate(itemToStore)
		let retrievedItem = identifierCache.get(itemToStore.cloudPath)
		XCTAssertNotNil(retrievedItem)
		XCTAssertEqual(itemToStore, retrievedItem)
	}

	func testUpdateWithDifferentIdentifierForCachedCloudPath() throws {
		let cloudPath = CloudPath("/abc/test--a-")
		let itemToStore = GoogleDriveItem(cloudPath: cloudPath, identifier: "TestABC--1234@^", itemType: .folder, shortcut: nil)
		try identifierCache.addOrUpdate(itemToStore)
		let newItemToStore = GoogleDriveItem(cloudPath: cloudPath, identifier: "NewerIdentifer879978123.1-", itemType: .folder, shortcut: nil)
		try identifierCache.addOrUpdate(newItemToStore)
		let retrievedItem = identifierCache.get(cloudPath)
		XCTAssertNotNil(retrievedItem)
		XCTAssertEqual(newItemToStore, retrievedItem)
	}

	func testGetAfterInvalidatingDifferentIdentifier() throws {
		let cloudPath = CloudPath("/abc/test--a-")
		let itemToStore = GoogleDriveItem(cloudPath: cloudPath, identifier: "TestABC--1234@^", itemType: .folder, shortcut: nil)
		try identifierCache.addOrUpdate(itemToStore)
		let retrievedItem = identifierCache.get(cloudPath)
		XCTAssertNotNil(retrievedItem)
		let secondCloudPath = CloudPath("/test/AAAAAAAAAAAA/test.txt")
		let secondItemToStore = GoogleDriveItem(cloudPath: secondCloudPath, identifier: "SecondIdentifer@@^1!!´´$", itemType: .folder, shortcut: nil)
		try identifierCache.addOrUpdate(secondItemToStore)
		try identifierCache.invalidate(itemToStore)
		XCTAssertNil(identifierCache.get(cloudPath))
		let stillCachedItem = identifierCache.get(secondCloudPath)
		XCTAssertNotNil(stillCachedItem)
		XCTAssertEqual(secondItemToStore, stillCachedItem)
	}

	func testInvalidateForNonExistentCloudPath() throws {
		let cloudPath = CloudPath("/abc/test--a-")
		XCTAssertNil(identifierCache.get(cloudPath))
		let nonExistentItem = GoogleDriveItem(cloudPath: cloudPath, identifier: "TestABC--1234@^", itemType: .folder, shortcut: nil)
		try identifierCache.invalidate(nonExistentItem)
	}
}
