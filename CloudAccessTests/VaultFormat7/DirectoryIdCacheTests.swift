//
//  DirectoryIdCacheTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 15.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
@testable import CloudAccess

class DirectoryIdCacheTests: XCTestCase {
	func testGetCached() throws {
		let cache = try DirectoryIdCache()
		let path = URL(fileURLWithPath: "/foo/bar")
		let dirId = Data("foobar".utf8)

		try cache.addToCache(path, dirId: dirId)

		XCTAssertEqual(dirId, try cache.getCached(path))
	}

	func testInvalidate() throws {
		let cache = try DirectoryIdCache()
		let path = URL(fileURLWithPath: "/foo")
		let subPath1 = URL(fileURLWithPath: "/foo/bar")
		let subPath2 = URL(fileURLWithPath: "/foo/baz")
		let siblingPath = URL(fileURLWithPath: "/bar/foo")
		let dirId = Data("foobar".utf8)

		try cache.addToCache(path, dirId: dirId)
		try cache.addToCache(subPath1, dirId: dirId)
		try cache.addToCache(subPath2, dirId: dirId)
		try cache.addToCache(siblingPath, dirId: dirId)
		try cache.invalidate(path)

		XCTAssertNil(try cache.getCached(path))
		XCTAssertNil(try cache.getCached(subPath1))
		XCTAssertNil(try cache.getCached(subPath2))
		XCTAssertEqual(dirId, try cache.getCached(siblingPath))
	}
}
