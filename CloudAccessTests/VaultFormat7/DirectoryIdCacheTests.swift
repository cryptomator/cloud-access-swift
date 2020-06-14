//
//  DirectoryIdCacheTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 15.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
@testable import CloudAccess
@testable import Promises

class DirectoryIdCacheTests: XCTestCase {
	func testContainsRootPath() throws {
		let cache = try DirectoryIdCache()
		let path = URL(fileURLWithPath: "/")

		XCTAssertEqual(Data([]), try cache.getCached(path))
	}

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

	func testRecursiveGet() throws {
		let cache = try DirectoryIdCache()
		let url = URL(fileURLWithPath: "/one/two/three")

		var misses: [String] = []
		let result = cache.get(url, onMiss: { (cleartextURL, parentDirId) -> Promise<Data> in
			let dirId: String = {
				switch cleartextURL.lastPathComponent {
				case "one":
					XCTAssertEqual(Data(), parentDirId)
					return "ONE"
				case "two":
					XCTAssertEqual(Data("ONE".utf8), parentDirId)
					return "TWO"
				case "three":
					XCTAssertEqual(Data("TWO".utf8), parentDirId)
					return "THREE"
				default:
					XCTFail()
					return "UNEXPECTED"
				}
			}()
			misses.append(dirId)
			return Promise(Data(dirId.utf8))
		})

		result.then { data in
			XCTAssertEqual(Data("THREE".utf8), data)
		}

		XCTAssertTrue(waitForPromises(timeout: 1.0))
		XCTAssertEqual("ONE", misses[0])
		XCTAssertEqual("TWO", misses[1])
		XCTAssertEqual("THREE", misses[2])
	}
}
