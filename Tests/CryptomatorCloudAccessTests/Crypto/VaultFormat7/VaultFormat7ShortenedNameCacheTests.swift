//
//  VaultFormat7ShortenedNameCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
@testable import CryptomatorCloudAccess

class VaultFormat7ShortenedNameCacheTests: XCTestCase {
	let vaultPath = CloudPath("/foo/bar")
	var cache: VaultFormat7ShortenedNameCache!

	override func setUpWithError() throws {
		cache = try VaultFormat7ShortenedNameCache(vaultPath: vaultPath)
	}

	func testGetCached() throws {
		let shortenedName = "-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
		let originalName = "\(String(repeating: "a", count: 217)).c9r"

		try cache.addToCache(shortenedName, originalName: originalName)

		XCTAssertEqual(originalName, try cache.getCached(shortenedName))
	}

	func testgetShortenedPath1() throws {
		let longName = String(repeating: "a", count: 217) // 221 chars when including .c9r
		let originalPath = CloudPath("/foo/bar/d/2/30/\(longName).c9r")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertNotNil(shortened.c9sDir)
		XCTAssertEqual("\(longName).c9r", shortened.c9sDir!.originalName)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", shortened.c9sDir!.cloudPath.path)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", shortened.cloudPath.path)
		XCTAssertTrue(shortened.pointsToC9S)
	}

	func testgetShortenedPath2() throws {
		let longName = String(repeating: "a", count: 217) // 221 chars when including .c9r
		let originalPath = CloudPath("/foo/bar/d/2/30/\(longName).c9r/dir.c9r")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertNotNil(shortened.c9sDir)
		XCTAssertEqual("\(longName).c9r", shortened.c9sDir!.originalName)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", shortened.c9sDir!.cloudPath.path)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r", shortened.cloudPath.path)
		XCTAssertFalse(shortened.pointsToC9S)
	}

	func testgetShortenedPath3() throws {
		let originalPath = CloudPath("/foo/bar/d/2/30")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertNil(shortened.c9sDir)
		XCTAssertEqual("/foo/bar/d/2/30", shortened.cloudPath.path)
		XCTAssertFalse(shortened.pointsToC9S)
	}

	func testgetOriginalPath1() {
		let shortened = CloudPath("/foo/bar/d/2/30/shortened.c9s")
		let expectation = XCTestExpectation(description: "callback called")

		cache.getOriginalPath(shortened) { cloudPath -> Promise<Data> in
			XCTAssertEqual("/foo/bar/d/2/30/shortened.c9s", cloudPath.path)
			return Promise("loooong.c9r".data(using: .utf8)!)
		}.then { longName in
			XCTAssertEqual("/foo/bar/d/2/30/loooong.c9r", longName.path)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testgetOriginalPath2() {
		let shortened = CloudPath("/foo/bar/d/2/30/shortened.c9s/dir.c9r")
		let expectation = XCTestExpectation(description: "callback called")

		cache.getOriginalPath(shortened) { cloudPath -> Promise<Data> in
			XCTAssertEqual("/foo/bar/d/2/30/shortened.c9s", cloudPath.path)
			return Promise("loooong.c9r".data(using: .utf8)!)
		}.then { longName in
			XCTAssertEqual("/foo/bar/d/2/30/loooong.c9r/dir.c9r", longName.path)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeflatePath1() throws {
		let originalPath = CloudPath("/foo/bar/d/2/30/loooooong.c9r/dir.c9r")
		let shortened = cache.deflatePath(originalPath, with: "short.c9s")

		XCTAssertEqual("/foo/bar/d/2/30/short.c9s/dir.c9r", shortened.path)
	}

	func testDeflatePath2() throws {
		let originalPath = CloudPath("/foo/bar/d/2/30/loooooong.c9r")
		let shortened = cache.deflatePath(originalPath, with: "short.c9s")

		XCTAssertEqual("/foo/bar/d/2/30/short.c9s", shortened.path)
	}

	func testDeflatePath3() throws {
		let originalPath = CloudPath("/foo/bar/d/2/30/loooooong.c9r/dir.c9r/baz")
		let shortened = cache.deflatePath(originalPath, with: "short.c9s")

		XCTAssertEqual("/foo/bar/d/2/30/short.c9s/dir.c9r/baz", shortened.path)
	}
}
