//
//  DirectoryIdCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 15.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import os
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

	func testInvalidateMatchesPathsLiterally() throws {
		let dirId = Data("foobar".utf8)
		let cases: [(invalidated: String, kept: [String])] = [
			("/a", ["/ab", "/A/x", "/a_b"]),
			("/a_b", ["/aXb/x"]),
			("/a%", ["/abc"])
		]
		for (invalidated, kept) in cases {
			let cache = try DirectoryIdCache()
			for path in [invalidated, invalidated + "/x"] + kept {
				try cache.addOrUpdate(CloudPath(path), dirId: dirId)
			}

			try cache.invalidate(CloudPath(invalidated))

			XCTAssertNil(try cache.get(CloudPath(invalidated)), invalidated)
			XCTAssertNil(try cache.get(CloudPath(invalidated + "/x")), invalidated)
			for path in kept {
				XCTAssertEqual(dirId, try cache.get(CloudPath(path)), "\(path) after invalidating \(invalidated)")
			}
		}
	}

	func testInvalidateRootRemovesEveryPath() throws {
		try cache.addOrUpdate(CloudPath("/foo/bar"), dirId: Data("foobar".utf8))

		try cache.invalidate(CloudPath("/"))

		XCTAssertNil(try cache.get(CloudPath("/")))
		XCTAssertNil(try cache.get(CloudPath("/foo/bar")))
	}

	func testRecursiveGet() async throws {
		let path = CloudPath("/one/two/three")

		let misses = OSAllocatedUnfairLock(initialState: [String]())
		let data = try await cache.get(path, onMiss: { cleartextPath, parentDirId in
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
			misses.withLock { $0.append(dirId) }
			return Data(dirId.utf8)
		})
		XCTAssertEqual(Data("THREE".utf8), data)

		XCTAssertEqual(["ONE", "TWO", "THREE"], misses.withLock { $0 })
	}
}
