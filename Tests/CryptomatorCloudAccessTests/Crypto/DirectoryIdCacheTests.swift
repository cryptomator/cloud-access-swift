//
//  DirectoryIdCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 15.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DirectoryIdCacheTests: XCTestCase {
	var cache: DirectoryIdCache!

	override func setUpWithError() throws {
		cache = try DirectoryIdCache()
	}

	func testContainsRootPath() throws {
		let path = CloudPath("/")

		XCTAssertEqual(Data([]), try cache.get(path))
	}

	func testGet() throws {
		let path = CloudPath("/foo/bar")
		let dirId = Data("foobar".utf8)

		try cache.addOrUpdate(path, dirId: dirId)

		XCTAssertEqual(dirId, try cache.get(path))
	}

	func testInvalidate() throws {
		let path = CloudPath("/foo")
		let subPath1 = CloudPath("/foo/bar")
		let subPath2 = CloudPath("/foo/baz")
		let siblingPath = CloudPath("/bar/foo")
		let dirId = Data("foobar".utf8)

		try cache.addOrUpdate(path, dirId: dirId)
		try cache.addOrUpdate(subPath1, dirId: dirId)
		try cache.addOrUpdate(subPath2, dirId: dirId)
		try cache.addOrUpdate(siblingPath, dirId: dirId)
		try cache.invalidate(path)

		XCTAssertNil(try cache.get(path))
		XCTAssertNil(try cache.get(subPath1))
		XCTAssertNil(try cache.get(subPath2))
		XCTAssertEqual(dirId, try cache.get(siblingPath))
	}

	func testRecursiveGet() throws {
		let expectation = XCTestExpectation(description: "recursiveGet")
		let path = CloudPath("/one/two/three")

		var misses: [String] = []
		let result = cache.get(path, onMiss: { cleartextPath, parentDirId -> Promise<Data> in
			let dirId: String = {
				switch cleartextPath.lastPathComponent {
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
					XCTFail("Unexpected path component: \(cleartextPath.lastPathComponent)")
					return "UNEXPECTED"
				}
			}()
			misses.append(dirId)
			return Promise(Data(dirId.utf8))
		})

		result.then { data in
			XCTAssertEqual(Data("THREE".utf8), data)
		}.always {
			expectation.fulfill()
		}

		wait(for: [expectation], timeout: 1.0)
		XCTAssertEqual("ONE", misses[0])
		XCTAssertEqual("TWO", misses[1])
		XCTAssertEqual("THREE", misses[2])
	}
}
