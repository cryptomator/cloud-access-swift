//
//  VaultFormat6ShortenedNameCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
@testable import CryptomatorCloudAccess

class VaultFormat6ShortenedNameCacheTests: XCTestCase {
	let vaultPath = CloudPath("/foo/bar")
	var cache: VaultFormat6ShortenedNameCache!

	override func setUpWithError() throws {
		cache = try VaultFormat6ShortenedNameCache(vaultPath: vaultPath)
	}

	func testGetCached() throws {
		let shortenedName = "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng"
		let originalName = String(repeating: "a", count: 130)

		try cache.addToCache(shortenedName, originalName: originalName)

		XCTAssertEqual(originalName, try cache.getCached(shortenedName))
	}

	func testgetShortenedPath1() throws {
		let longName = String(repeating: "a", count: 130)
		let originalPath = CloudPath("/foo/bar/d/2/30/\(longName)")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertEqual("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng", shortened.cloudPath.path)
		XCTAssertTrue(shortened.pointsToLNG)
	}

	func testgetShortenedPath2() throws {
		let originalPath = CloudPath("/foo/bar/d/2/30")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertEqual("/foo/bar/d/2/30", shortened.cloudPath.path)
		XCTAssertFalse(shortened.pointsToLNG)
	}

	func testgetOriginalPath() {
		let shortened = CloudPath("/foo/bar/d/2/30/shortened.lng")
		let expectation = XCTestExpectation(description: "callback called")

		cache.getOriginalPath(shortened) { lngFileName -> Promise<Data> in
			XCTAssertEqual("shortened.lng", lngFileName)
			return Promise("loooong".data(using: .utf8)!)
		}.then { longName in
			XCTAssertEqual("/foo/bar/d/2/30/loooong", longName.path)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeflatePath() throws {
		let originalPath = CloudPath("/foo/bar/d/2/30/loooooong")
		let shortened = cache.deflatePath(originalPath, with: "short.lng")

		XCTAssertEqual("/foo/bar/d/2/30/short.lng", shortened.path)
	}
}
