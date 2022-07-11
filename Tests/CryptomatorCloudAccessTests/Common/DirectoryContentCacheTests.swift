//
//  DirectoryContentCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 11.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import GRDB
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DirectoryContentCacheTests: XCTestCase {
	var cache: DirectoryContentCache!
	let maxPageSize = 2
	let rootItems: [CloudItemMetadata] = [
		.init(name: "test.txt", cloudPath: .init("/test.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
		.init(name: "test1.txt", cloudPath: .init("/test1.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
		.init(name: "subfolder", cloudPath: .init("/subfolder"), itemType: .folder, lastModifiedDate: nil, size: nil)
	]
	let subFolderItems: [CloudItemMetadata] = [
		.init(name: "test.txt", cloudPath: .init("/subfolder/test.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
		.init(name: "test1.txt", cloudPath: .init("/subfolder/test1.txt"), itemType: .file, lastModifiedDate: nil, size: nil)
	]
	let subfolderPath = CloudPath("/subfolder")

	override func setUpWithError() throws {
		let inMemoryDB = DatabaseQueue()
		cache = try DirectoryContentDBCache(dbWriter: inMemoryDB, maxPageSize: maxPageSize)
	}

	func testCacheAndRetrieveElement() throws {
		let cloudItemMetadata = CloudItemMetadata(name: "test.txt", cloudPath: CloudPath("/test.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175)
		try cache.save(cloudItemMetadata, for: .root, index: 1)
		let response = try cache.getResponse(for: .root, pageToken: nil)
		XCTAssertNil(response.nextPageToken)
		let elements = response.elements
		XCTAssertEqual(1, elements.count)
		let cachedElement = try XCTUnwrap(elements.first)
		XCTAssertEqual(cloudItemMetadata, cachedElement)
	}

	func testCacheAndRetrieveElementWithoutDate() throws {
		let cloudItemMetadata = CloudItemMetadata(name: "test.txt", cloudPath: CloudPath("/test.txt"), itemType: .file, lastModifiedDate: nil, size: 54175)
		try cache.save(cloudItemMetadata, for: .root, index: 1)
		let response = try cache.getResponse(for: .root, pageToken: nil)
		XCTAssertNil(response.nextPageToken)
		let elements = response.elements
		XCTAssertEqual(1, elements.count)
		let cachedElement = try XCTUnwrap(elements.first)
		XCTAssertEqual(cloudItemMetadata, cachedElement)
	}

	func testCacheAndRetrieveFolder() throws {
		let cloudItemMetadata = CloudItemMetadata(name: "test", cloudPath: CloudPath("/test"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: nil)
		try cache.save(cloudItemMetadata, for: .root, index: 1)
		let response = try cache.getResponse(for: .root, pageToken: nil)
		XCTAssertNil(response.nextPageToken)
		let elements = response.elements
		XCTAssertEqual(1, elements.count)
		let cachedElement = try XCTUnwrap(elements.first)
		XCTAssertEqual(cloudItemMetadata, cachedElement)
	}

	func testCacheAndRetrieveElementWithoutDateAndSize() throws {
		let cloudItemMetadata = CloudItemMetadata(name: "test.txt", cloudPath: CloudPath("/test.txt"), itemType: .file, lastModifiedDate: nil, size: nil)
		try cache.save(cloudItemMetadata, for: .root, index: 1)
		let response = try cache.getResponse(for: .root, pageToken: nil)
		XCTAssertNil(response.nextPageToken)
		let elements = response.elements
		XCTAssertEqual(1, elements.count)
		let cachedElement = try XCTUnwrap(elements.first)
		XCTAssertEqual(cloudItemMetadata, cachedElement)
	}

	func testPagination() throws {
		try insertItemsIntoCache(rootItems, folderEnumerationPath: .root)
		try insertItemsIntoCache(subFolderItems, folderEnumerationPath: subfolderPath)

		let initialRootCacheResponse = try cache.getResponse(for: .root, pageToken: nil)
		XCTAssertEqual("2:4", initialRootCacheResponse.nextPageToken)
		XCTAssertEqual(Array(rootItems.prefix(2)), initialRootCacheResponse.elements)

		let finalRootCacheResponse = try cache.getResponse(for: .root, pageToken: initialRootCacheResponse.nextPageToken)
		XCTAssertNil(finalRootCacheResponse.nextPageToken)
		XCTAssertEqual(Array(rootItems.suffix(1)), finalRootCacheResponse.elements)

		let subfolderCacheResponse = try cache.getResponse(for: subfolderPath, pageToken: nil)
		XCTAssertNil(subfolderCacheResponse.nextPageToken)
		XCTAssertEqual(subFolderItems, subfolderCacheResponse.elements)
	}

	func testClearCache() throws {
		try insertItemsIntoCache(rootItems, folderEnumerationPath: .root)
		try insertItemsIntoCache(subFolderItems, folderEnumerationPath: subfolderPath)
		try cache.clearCache(for: .root)
		let rootCacheResponse = try cache.getResponse(for: .root, pageToken: nil)
		XCTAssertNil(rootCacheResponse.nextPageToken)
		XCTAssert(rootCacheResponse.elements.isEmpty)

		let subfolderCacheResponse = try cache.getResponse(for: subfolderPath, pageToken: nil)
		XCTAssertNil(subfolderCacheResponse.nextPageToken)
		XCTAssertEqual(subFolderItems, subfolderCacheResponse.elements)
	}

	func testInvalidPageToken() throws {
		try insertItemsIntoCache(rootItems, folderEnumerationPath: .root)
		XCTAssertThrowsError(try cache.getResponse(for: .root, pageToken: "Foo:Bar"), "") { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}

		XCTAssertThrowsError(try cache.getResponse(for: .root, pageToken: "-1:0"), "") { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}

		XCTAssertThrowsError(try cache.getResponse(for: .root, pageToken: "0:0"), "") { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}

		XCTAssertThrowsError(try cache.getResponse(for: .root, pageToken: "1:0"), "") { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}

		XCTAssertThrowsError(try cache.getResponse(for: .root, pageToken: "3:5"), "") { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}
	}

	private func insertItemsIntoCache(_ items: [CloudItemMetadata], folderEnumerationPath: CloudPath) throws {
		var cachedItemIndex: Int64 = 0
		for item in items {
			cachedItemIndex += 1
			try cache.save(item, for: folderEnumerationPath, index: cachedItemIndex)
		}
	}
}
