//
//  OneDriveIdentifierCacheTests.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 09.07.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class OneDriveIdentifierCacheTests: XCTestCase {
	var identifierCache: OneDriveIdentifierCache!

	override func setUpWithError() throws {
		identifierCache = try OneDriveIdentifierCache()
	}

	func testRootItemIsCachedAtStart() throws {
		let expectedRootItem = OneDriveItem(cloudPath: CloudPath("/"), identifier: "root", driveIdentifier: nil, itemType: .folder)
		let rootItem = identifierCache.get(expectedRootItem.cloudPath)
		XCTAssertNotNil(rootItem)
		XCTAssertEqual(expectedRootItem, rootItem)
	}

	func testAddAndGetForFileCloudPath() throws {
		let itemToStore = OneDriveItem(cloudPath: CloudPath("/abc/test.txt"), identifier: "TestABC--1234@^", driveIdentifier: nil, itemType: .file)
		try identifierCache.addOrUpdate(itemToStore)
		let retrievedItem = identifierCache.get(itemToStore.cloudPath)
		XCTAssertNotNil(retrievedItem)
		XCTAssertEqual(itemToStore, retrievedItem)
	}

	func testAddAndGetForFolderCloudPath() throws {
		let itemToStore = OneDriveItem(cloudPath: CloudPath("/abc/test--a-"), identifier: "TestABC--1234@^", driveIdentifier: nil, itemType: .folder)
		try identifierCache.addOrUpdate(itemToStore)
		let retrievedItem = identifierCache.get(itemToStore.cloudPath)
		XCTAssertNotNil(retrievedItem)
		XCTAssertEqual(itemToStore, retrievedItem)
	}

	func testUpdateWithDifferentIdentifierForCachedCloudPath() throws {
		let cloudPath = CloudPath("/abc/test--a-")
		let itemToStore = OneDriveItem(cloudPath: cloudPath, identifier: "TestABC--1234@^", driveIdentifier: nil, itemType: .folder)
		try identifierCache.addOrUpdate(itemToStore)
		let newItemToStore = OneDriveItem(cloudPath: cloudPath, identifier: "NewerIdentifer879978123.1-", driveIdentifier: nil, itemType: .folder)
		try identifierCache.addOrUpdate(newItemToStore)
		let retrievedItem = identifierCache.get(cloudPath)
		XCTAssertNotNil(retrievedItem)
		XCTAssertEqual(newItemToStore, retrievedItem)
	}

	func testInvalidateIncludingSubPaths() throws {
		let path = CloudPath("/foo")
		let itemToStore = OneDriveItem(cloudPath: path, identifier: "foo", driveIdentifier: nil, itemType: .folder)
		try identifierCache.addOrUpdate(itemToStore)

		let subPath1 = CloudPath("/foo/bar")
		let subItemToStore1 = OneDriveItem(cloudPath: subPath1, identifier: "sub1", driveIdentifier: nil, itemType: .folder)
		try identifierCache.addOrUpdate(subItemToStore1)

		let subPath2 = CloudPath("/foo/baz")
		let subItemToStore2 = OneDriveItem(cloudPath: subPath2, identifier: "sub2", driveIdentifier: nil, itemType: .folder)
		try identifierCache.addOrUpdate(subItemToStore2)

		let siblingPath = CloudPath("/bar/foo")
		let siblingItemToStore = OneDriveItem(cloudPath: siblingPath, identifier: "sibling", driveIdentifier: nil, itemType: .folder)
		try identifierCache.addOrUpdate(siblingItemToStore)

		try identifierCache.invalidate(itemToStore)
		XCTAssertNil(identifierCache.get(path))
		XCTAssertNil(identifierCache.get(subPath1))
		XCTAssertNil(identifierCache.get(subPath2))
		XCTAssertEqual(siblingItemToStore, identifierCache.get(siblingPath))
	}

	func testGetAfterInvalidatingDifferentIdentifier() throws {
		let cloudPath = CloudPath("/abc/test--a-")
		let itemToStore = OneDriveItem(cloudPath: cloudPath, identifier: "TestABC--1234@^", driveIdentifier: nil, itemType: .folder)
		try identifierCache.addOrUpdate(itemToStore)
		let retrievedItem = identifierCache.get(cloudPath)
		XCTAssertNotNil(retrievedItem)
		let secondCloudPath = CloudPath("/test/AAAAAAAAAAAA/test.txt")
		let secondItemToStore = OneDriveItem(cloudPath: secondCloudPath, identifier: "SecondIdentifer@@^1!!´´$", driveIdentifier: nil, itemType: .folder)
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
		let nonExistentItem = OneDriveItem(cloudPath: cloudPath, identifier: "TestABC--1234@^", driveIdentifier: nil, itemType: .folder)
		try identifierCache.invalidate(nonExistentItem)
	}
}
