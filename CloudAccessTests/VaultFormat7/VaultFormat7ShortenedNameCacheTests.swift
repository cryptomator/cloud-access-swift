//
//  VaultFormat7ShortenedNameCacheTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
@testable import CloudAccess

class VaultFormat7ShortenedNameCacheTests: XCTestCase {
	var vaultRoot: URL!
	var cache: VaultFormat7ShortenedNameCache!

	override func setUpWithError() throws {
		vaultRoot = URL(fileURLWithPath: "/foo/bar", isDirectory: true)
		cache = try VaultFormat7ShortenedNameCache(vaultURL: vaultRoot)
	}

	func testGetShortenedURL1() throws {
		let longName = String(repeating: "a", count: 217) // 221 chars when including .c9r
		let originalURL = URL(fileURLWithPath: "/foo/bar/d/2/30/\(longName).c9r", isDirectory: false)
		let shortened = cache.getShortenedURL(originalURL)

		XCTAssertNotNil(shortened.c9sDir)
		XCTAssertEqual("\(longName).c9r", shortened.c9sDir!.originalName)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", shortened.c9sDir!.url.path)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", shortened.url.path)
		XCTAssertTrue(shortened.pointsToC9S)
		XCTAssertTrue(shortened.c9sDir!.url.hasDirectoryPath)
		XCTAssertFalse(shortened.url.hasDirectoryPath)
	}

	func testGetShortenedURL2() throws {
		let longName = String(repeating: "a", count: 217) // 221 chars when including .c9r
		let originalURL = URL(fileURLWithPath: "/foo/bar/d/2/30/\(longName).c9r/dir.c9r", isDirectory: true)
		let shortened = cache.getShortenedURL(originalURL)

		XCTAssertNotNil(shortened.c9sDir)
		XCTAssertEqual("\(longName).c9r", shortened.c9sDir!.originalName)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", shortened.c9sDir!.url.path)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r", shortened.url.path)
		XCTAssertFalse(shortened.pointsToC9S)
		XCTAssertTrue(shortened.c9sDir!.url.hasDirectoryPath)
		XCTAssertTrue(shortened.url.hasDirectoryPath)
	}

	func testGetShortenedURL3() throws {
		let originalURL = URL(fileURLWithPath: "/foo/bar/d/2/30", isDirectory: true)
		let shortened = cache.getShortenedURL(originalURL)

		XCTAssertNil(shortened.c9sDir)
		XCTAssertEqual("/foo/bar/d/2/30", shortened.url.path)
		XCTAssertFalse(shortened.pointsToC9S)
		XCTAssertTrue(shortened.url.hasDirectoryPath)
	}

	func testGetOriginalURL1() {
		let shortened = URL(fileURLWithPath: "/foo/bar/d/2/30/shortened.c9s", isDirectory: false)
		let expectation = XCTestExpectation(description: "callback called")

		cache.getOriginalURL(shortened) { url -> Promise<Data> in
			XCTAssertEqual("/foo/bar/d/2/30/shortened.c9s", url.path)
			return Promise("loooong.c9r".data(using: .utf8)!)
		}.then { longName in
			XCTAssertEqual("/foo/bar/d/2/30/loooong.c9r", longName.path)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testGetOriginalURL2() {
		let shortened = URL(fileURLWithPath: "/foo/bar/d/2/30/shortened.c9s/dir.c9r", isDirectory: false)
		let expectation = XCTestExpectation(description: "callback called")

		cache.getOriginalURL(shortened) { url -> Promise<Data> in
			XCTAssertEqual("/foo/bar/d/2/30/shortened.c9s", url.path)
			return Promise("loooong.c9r".data(using: .utf8)!)
		}.then { longName in
			XCTAssertEqual("/foo/bar/d/2/30/loooong.c9r/dir.c9r", longName.path)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testReplaceCiphertextFileNameInURL1() throws {
		let originalURL = URL(fileURLWithPath: "/foo/bar/d/2/30/loooooong.c9r/dir.c9r", isDirectory: true)
		let shortened = cache.replaceCiphertextFileNameInURL(originalURL, with: "short.c9s")

		XCTAssertEqual("/foo/bar/d/2/30/short.c9s/dir.c9r", shortened.path)
		XCTAssertTrue(shortened.hasDirectoryPath)
	}

	func testReplaceCiphertextFileNameInURL2() throws {
		let originalURL = URL(fileURLWithPath: "/foo/bar/d/2/30/loooooong.c9r", isDirectory: false)
		let shortened = cache.replaceCiphertextFileNameInURL(originalURL, with: "short.c9s")

		XCTAssertEqual("/foo/bar/d/2/30/short.c9s", shortened.path)
		XCTAssertFalse(shortened.hasDirectoryPath)
	}

	func testReplaceCiphertextFileNameInURL3() throws {
		let originalURL = URL(fileURLWithPath: "/foo/bar/d/2/30/loooooong.c9r/dir.c9r/bullshit", isDirectory: false)
		let shortened = cache.replaceCiphertextFileNameInURL(originalURL, with: "short.c9s")

		XCTAssertEqual("/foo/bar/d/2/30/short.c9s/dir.c9r/bullshit", shortened.path)
		XCTAssertFalse(shortened.hasDirectoryPath)
	}
}
