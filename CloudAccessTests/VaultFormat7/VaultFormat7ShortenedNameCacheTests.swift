//
//  VaultFormat7ShortenedNameCacheTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
@testable import CloudAccess

class VaultFormat7ShortenedNameCacheTests: XCTestCase {
	func testReplaceCiphertextFileName1() throws {
		let vaultRoot = URL(fileURLWithPath: "/foo/bar")
		let cache = VaultFormat7ShortenedNameCache(vaultURL: vaultRoot)

		let originalURL = URL(fileURLWithPath: "/foo/bar/d/2/30/loooooong.c9r/dir.c9r", isDirectory: true)
		let shortened = cache.replaceCiphertextFileName(originalURL, with: "short.c9s")

		XCTAssertEqual("/foo/bar/d/2/30/short.c9s/dir.c9r", shortened.path)
		XCTAssertTrue(shortened.hasDirectoryPath)
	}

	func testReplaceCiphertextFileName2() throws {
		let vaultRoot = URL(fileURLWithPath: "/foo")
		let cache = VaultFormat7ShortenedNameCache(vaultURL: vaultRoot)

		let originalURL = URL(fileURLWithPath: "/foo/d/2/30/loooooong.c9r")
		let shortened = cache.replaceCiphertextFileName(originalURL, with: "short.c9s")

		XCTAssertEqual("/foo/d/2/30/short.c9s", shortened.path)
		XCTAssertFalse(shortened.hasDirectoryPath)
	}

	func testReplaceCiphertextFileName3() throws {
		let vaultRoot = URL(fileURLWithPath: "/")
		let cache = VaultFormat7ShortenedNameCache(vaultURL: vaultRoot)

		let originalURL = URL(fileURLWithPath: "/d/2/30/loooooong.c9r/dir.c9r/bullshit")
		let shortened = cache.replaceCiphertextFileName(originalURL, with: "short.c9s")

		XCTAssertEqual("/d/2/30/short.c9s/dir.c9r/bullshit", shortened.path)
		XCTAssertFalse(shortened.hasDirectoryPath)
	}
}
