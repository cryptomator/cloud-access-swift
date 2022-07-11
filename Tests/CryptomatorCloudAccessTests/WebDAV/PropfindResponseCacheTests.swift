//
//  PropfindResponseCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 07.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import GRDB
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
/*
 class PropfindResponseCacheTests: XCTestCase {
 	var cache: PropfindResponseCache!

 	override func setUpWithError() throws {
 		let inMemoryDB = DatabaseQueue()
 		cache = try PropfindResponseCache(dbWriter: inMemoryDB, maxPageSize: .max)
 	}

 	func testCacheElement() throws {
 		let propfindResponseElement = PropfindResponseElement(depth: 1, url: URL(string: "/0.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175)
 		try cache.save(propfindResponseElement, for: .root, index: 1)
 		let response = try cache.getResponse(for: .root, pageToken: nil)
 		XCTAssertNil(response.nextPageToken)
 		let elements = response.elements
 		XCTAssertEqual(1, elements.count)
 		let cachedElement = try XCTUnwrap(elements.first)
 		XCTAssertEqual(propfindResponseElement, cachedElement)
 	}

 	func testCacheElementWithoutDate() throws {
 		let propfindResponseElement = PropfindResponseElement(depth: 1, url: URL(string: "/0.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: nil, contentLength: 54175)
 		try cache.save(propfindResponseElement, for: .root, index: 1)
 		let response = try cache.getResponse(for: .root, pageToken: nil)
 		XCTAssertNil(response.nextPageToken)
 		let elements = response.elements
 		XCTAssertEqual(1, elements.count)
 		let cachedElement = try XCTUnwrap(elements.first)
 		XCTAssertEqual(propfindResponseElement, cachedElement)
 	}

 	func testCacheResponseIsOrdered() throws {
 		let rootPropfindResponseElement = PropfindResponseElement(depth: 0, url: URL(string: "/", relativeTo: URL(string: "/")!)!, collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:48:41 GMT"), contentLength: nil)
 		let propfindResponseElement = PropfindResponseElement(depth: 1, url: URL(string: "/1.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175)
 		let anotherPropfindResponseElement = PropfindResponseElement(depth: 1, url: URL(string: "/0.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175)

 		try cache.save(rootPropfindResponseElement, for: .root, index: 1)
 		try cache.save(propfindResponseElement, for: .root, index: 2)
 		try cache.save(anotherPropfindResponseElement, for: .root, index: 3)
 		// sorted by depth and then by name
 		let expectedCachedElements = [
 			rootPropfindResponseElement,
 			anotherPropfindResponseElement,
 			propfindResponseElement
 		]
 		let response = try cache.getResponse(for: .root, pageToken: nil)
 		assertFullResponse(response, expectedPropfindResponseElements: expectedCachedElements)
 	}

 	func testCachePagination() throws {
 		let rootPropfindResponseElement = PropfindResponseElement(depth: 0, url: URL(string: "/", relativeTo: URL(string: "/")!)!, collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:48:41 GMT"), contentLength: nil)
 		let propfindResponseElement = PropfindResponseElement(depth: 1, url: URL(string: "/1.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175)
 		try cache.save(rootPropfindResponseElement, for: .root, index: 1)
 		try cache.save(propfindResponseElement, for: .root, index: 2)
 	}

 	func testClearCache() throws {
 		let propfindResponseElement = PropfindResponseElement(depth: 1, url: URL(string: "/0.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175)
 		try cache.save(propfindResponseElement, for: .root, index: 1)
 		let subfolderPath = CloudPath("/foo")
 		try cache.save(propfindResponseElement, for: subfolderPath, index: 1)
 		try cache.clearCache(for: .root)
 		let response = try cache.getResponse(for: .root, pageToken: nil)
 		XCTAssertNil(response.nextPageToken)
 		XCTAssert(response.elements.isEmpty)

 		assertFullResponse(try cache.getResponse(for: subfolderPath, pageToken: nil), expectedPropfindResponseElements: [propfindResponseElement])
 	}

 	private func assertFullResponse(_ response: PropfindResponseCache.CacheResponse, expectedPropfindResponseElements: [PropfindResponseElement]) {
 		XCTAssertNil(response.nextPageToken)
 		let cachedElements = response.elements
 		XCTAssertEqual(expectedPropfindResponseElements, cachedElements)
 	}
 }
 */
