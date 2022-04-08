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

	func testAddAndGetForShortcut() throws {
		let shortcut = GoogleDriveShortcut(targetIdentifier: "TestABC--1234@^", targetItemType: .file)
		let itemToStore = GoogleDriveItem(cloudPath: CloudPath("/abc/shortcut"), identifier: "ShortcutIdentifier", itemType: .symlink, shortcut: shortcut)
		try identifierCache.addOrUpdate(itemToStore)
		let retrievedItem = identifierCache.get(itemToStore.cloudPath)
		XCTAssertNotNil(retrievedItem)
		XCTAssertEqual(itemToStore, retrievedItem)
		XCTAssertEqual(shortcut, retrievedItem?.shortcut)
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

	func testInvalidateIncludingSubPaths() throws {
		let path = CloudPath("/foo")
		let itemToStore = GoogleDriveItem(cloudPath: path, identifier: "foo", itemType: .folder, shortcut: nil)
		try identifierCache.addOrUpdate(itemToStore)

		let subPath1 = CloudPath("/foo/bar")
		let subItemToStore1 = GoogleDriveItem(cloudPath: subPath1, identifier: "sub1", itemType: .folder, shortcut: nil)
		try identifierCache.addOrUpdate(subItemToStore1)

		let subPath2 = CloudPath("/foo/baz")
		let subItemToStore2 = GoogleDriveItem(cloudPath: subPath2, identifier: "sub2", itemType: .folder, shortcut: nil)
		try identifierCache.addOrUpdate(subItemToStore2)

		let siblingPath = CloudPath("/bar/foo")
		let siblingItemToStore = GoogleDriveItem(cloudPath: siblingPath, identifier: "sibling", itemType: .folder, shortcut: nil)
		try identifierCache.addOrUpdate(siblingItemToStore)

		try identifierCache.invalidate(itemToStore)
		XCTAssertNil(identifierCache.get(path))
		XCTAssertNil(identifierCache.get(subPath1))
		XCTAssertNil(identifierCache.get(subPath2))
		XCTAssertEqual(siblingItemToStore, identifierCache.get(siblingPath))
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
