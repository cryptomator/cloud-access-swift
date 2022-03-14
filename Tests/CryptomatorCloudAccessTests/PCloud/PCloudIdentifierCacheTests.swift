//
//  PCloudIdentifierCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 04.03.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class PCloudIdentifierCacheTests: XCTestCase {
	var identifierCache: PCloudIdentifierCache!

	override func setUpWithError() throws {
		identifierCache = try PCloudIdentifierCache()
	}

	func testRootItemIsCachedAtStart() throws {
		let expectedRootItem = PCloudItem(cloudPath: CloudPath("/"), identifier: "root", itemType: .folder)
		let rootItem = identifierCache.get(expectedRootItem.cloudPath)
		XCTAssertNotNil(rootItem)
		XCTAssertEqual(expectedRootItem, rootItem)
	}

	func testAddAndGetForFileCloudPath() throws {
		let itemToStore = PCloudItem(cloudPath: CloudPath("/abc/test.txt"), identifier: "TestABC--1234@^", itemType: .file)
		try identifierCache.addOrUpdate(itemToStore)
		let retrievedItem = identifierCache.get(itemToStore.cloudPath)
		XCTAssertNotNil(retrievedItem)
		XCTAssertEqual(itemToStore, retrievedItem)
	}

	func testAddAndGetForFolderCloudPath() throws {
		let itemToStore = PCloudItem(cloudPath: CloudPath("/abc/test--a-"), identifier: "TestABC--1234@^", itemType: .folder)
		try identifierCache.addOrUpdate(itemToStore)
		let retrievedItem = identifierCache.get(itemToStore.cloudPath)
		XCTAssertNotNil(retrievedItem)
		XCTAssertEqual(itemToStore, retrievedItem)
	}

	func testUpdateWithDifferentIdentifierForCachedCloudPath() throws {
		let cloudPath = CloudPath("/abc/test--a-")
		let itemToStore = PCloudItem(cloudPath: cloudPath, identifier: "TestABC--1234@^", itemType: .folder)
		try identifierCache.addOrUpdate(itemToStore)
		let newItemToStore = PCloudItem(cloudPath: cloudPath, identifier: "NewerIdentifer879978123.1-", itemType: .folder)
		try identifierCache.addOrUpdate(newItemToStore)
		let retrievedItem = identifierCache.get(cloudPath)
		XCTAssertNotNil(retrievedItem)
		XCTAssertEqual(newItemToStore, retrievedItem)
	}

	func testGetAfterInvalidatingDifferentIdentifier() throws {
		let cloudPath = CloudPath("/abc/test--a-")
		let itemToStore = PCloudItem(cloudPath: cloudPath, identifier: "TestABC--1234@^", itemType: .folder)
		try identifierCache.addOrUpdate(itemToStore)
		let retrievedItem = identifierCache.get(cloudPath)
		XCTAssertNotNil(retrievedItem)
		let secondCloudPath = CloudPath("/test/AAAAAAAAAAAA/test.txt")
		let secondItemToStore = PCloudItem(cloudPath: secondCloudPath, identifier: "SecondIdentifer@@^1!!´´$", itemType: .folder)
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
		let nonExistentItem = PCloudItem(cloudPath: cloudPath, identifier: "TestABC--1234@^", itemType: .folder)
		try identifierCache.invalidate(nonExistentItem)
	}
}
