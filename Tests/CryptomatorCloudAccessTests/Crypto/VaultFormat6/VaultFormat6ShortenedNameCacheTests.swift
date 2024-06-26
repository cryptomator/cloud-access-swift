//
//  VaultFormat6ShortenedNameCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import Promises
import XCTest

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

	func testGetShortenedPath1() throws {
		let longName = String(repeating: "a", count: 130)
		let originalPath = CloudPath("/foo/bar/d/2/30/\(longName)")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertEqual("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng", shortened.cloudPath.path)
		XCTAssertTrue(shortened.pointsToLNG)
	}

	func testGetShortenedPath2() throws {
		let originalPath = CloudPath("/foo/bar/d/2/30")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertEqual("/foo/bar/d/2/30", shortened.cloudPath.path)
		XCTAssertFalse(shortened.pointsToLNG)
	}

	func testGetOriginalPath() async throws {
		let shortened = CloudPath("/foo/bar/d/2/30/shortened.lng")

		let longName = try await cache.getOriginalPath(shortened) { lngFileName -> Promise<Data> in
			XCTAssertEqual("shortened.lng", lngFileName)
			return Promise(Data("loooong".utf8))
		}.async()
		XCTAssertEqual("/foo/bar/d/2/30/loooong", longName.path)
	}

	func testDeflatePath() throws {
		let originalPath = CloudPath("/foo/bar/d/2/30/loooooong")
		let shortened = cache.deflatePath(originalPath, with: "short.lng")

		XCTAssertEqual("/foo/bar/d/2/30/short.lng", shortened.path)
	}
}
