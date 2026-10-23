//
//  IdentifierCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 22.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// The cache of one item type, with the items built from a path, a number for the identifier and an item type.
struct IdentifierCacheProbe {
	let add: (_ path: String, _ identifier: Int, _ itemType: CloudItemType) throws -> Void
	let invalidate: (_ path: String) throws -> Void
	let contains: (_ path: String, _ identifier: Int, _ itemType: CloudItemType) -> Bool
	let containsNothing: (_ path: String) -> Bool
	let containsRootItem: () -> Bool

	init<Item: IdentifierCacheItem & Equatable>(makeItem: @escaping (_ cloudPath: CloudPath, _ identifier: Int, _ itemType: CloudItemType) -> Item) throws {
		let cache = try IdentifierCache<Item>()
		self.add = { try cache.addOrUpdate(makeItem(CloudPath($0), $1, $2)) }
		self.invalidate = { try cache.invalidate(makeItem(CloudPath($0), 0, .folder)) }
		self.contains = { cache.get(CloudPath($0)) == makeItem(CloudPath($0), $1, $2) }
		self.containsNothing = { cache.get(CloudPath($0)) == nil }
		self.containsRootItem = { cache.get(CloudPath("/")) == Item.rootItem }
	}
}

/// The tests of every item type's cache. Each subclass runs them for its item type.
class IdentifierCacheTests: XCTestCase {
	private var cache: IdentifierCacheProbe!

	/// XCTest runs the tests of this class only in its subclasses.
	override class var defaultTestSuite: XCTestSuite {
		return self == IdentifierCacheTests.self ? XCTestSuite(name: "IdentifierCacheTests") : super.defaultTestSuite
	}

	func makeCache() throws -> IdentifierCacheProbe {
		preconditionFailure("A subclass returns the cache of its item type")
	}

	override func setUpWithError() throws {
		cache = try makeCache()
	}

	func testRootItemIsCachedAtStart() {
		XCTAssertTrue(cache.containsRootItem())
	}

	func testAddAndGetForFileCloudPath() throws {
		try cache.add("/abc/test.txt", 1234, .file)

		XCTAssertTrue(cache.contains("/abc/test.txt", 1234, .file))
	}

	func testAddAndGetForFolderCloudPath() throws {
		try cache.add("/abc/test--a-", 1234, .folder)

		XCTAssertTrue(cache.contains("/abc/test--a-", 1234, .folder))
	}

	func testUpdateWithDifferentIdentifierForCachedCloudPath() throws {
		try cache.add("/abc/test--a-", 1234, .folder)
		try cache.add("/abc/test--a-", 5678, .folder)

		XCTAssertTrue(cache.contains("/abc/test--a-", 5678, .folder))
	}

	func testInvalidateIncludingSubPaths() throws {
		try cache.add("/foo", 123, .folder)
		try cache.add("/foo/bar", 234, .folder)
		try cache.add("/foo/baz", 345, .folder)
		try cache.add("/bar/foo", 456, .folder)

		try cache.invalidate("/foo")

		XCTAssertTrue(cache.containsNothing("/foo"))
		XCTAssertTrue(cache.containsNothing("/foo/bar"))
		XCTAssertTrue(cache.containsNothing("/foo/baz"))
		XCTAssertTrue(cache.contains("/bar/foo", 456, .folder))
	}

	func testInvalidateMatchesPathsLiterally() throws {
		let cases: [(invalidated: String, kept: [String])] = [
			("/a", ["/ab", "/A/x", "/a_b"]),
			("/a_b", ["/aXb/x"]),
			("/a%", ["/abc"])
		]
		for (invalidated, kept) in cases {
			let cache = try makeCache()
			for path in [invalidated, invalidated + "/x"] + kept {
				try cache.add(path, 1, .folder)
			}

			try cache.invalidate(invalidated)

			XCTAssertTrue(cache.containsNothing(invalidated), invalidated)
			XCTAssertTrue(cache.containsNothing(invalidated + "/x"), invalidated)
			for path in kept {
				XCTAssertTrue(cache.contains(path, 1, .folder), "\(path) after invalidating \(invalidated)")
			}
		}
	}

	func testInvalidateRootRemovesEveryItem() throws {
		try cache.add("/foo/bar", 123, .folder)

		try cache.invalidate("/")

		XCTAssertTrue(cache.containsNothing("/"))
		XCTAssertTrue(cache.containsNothing("/foo/bar"))
	}

	func testGetAfterInvalidatingDifferentIdentifier() throws {
		try cache.add("/abc/test--a-", 1234, .folder)
		try cache.add("/test/AAAAAAAAAAAA/test.txt", 9012, .folder)

		try cache.invalidate("/abc/test--a-")

		XCTAssertTrue(cache.containsNothing("/abc/test--a-"))
		XCTAssertTrue(cache.contains("/test/AAAAAAAAAAAA/test.txt", 9012, .folder))
	}

	func testInvalidateForNonExistentCloudPath() throws {
		XCTAssertTrue(cache.containsNothing("/abc/test--a-"))

		try cache.invalidate("/abc/test--a-")
	}
}

class BoxIdentifierCacheTests: IdentifierCacheTests {
	override func makeCache() throws -> IdentifierCacheProbe {
		return try IdentifierCacheProbe { BoxItem(cloudPath: $0, identifier: String($1), itemType: $2) }
	}
}

class PCloudIdentifierCacheTests: IdentifierCacheTests {
	override func makeCache() throws -> IdentifierCacheProbe {
		return try IdentifierCacheProbe { PCloudItem(cloudPath: $0, identifier: UInt64($1), itemType: $2) }
	}
}

class GoogleDriveIdentifierCacheTests: IdentifierCacheTests {
	override func makeCache() throws -> IdentifierCacheProbe {
		return try IdentifierCacheProbe { GoogleDriveItem(cloudPath: $0, identifier: "TestABC--\($1)@^", itemType: $2, shortcut: nil) }
	}

	func testAddAndGetForShortcut() throws {
		let cache = try IdentifierCache<GoogleDriveItem>()
		let shortcut = GoogleDriveShortcut(targetIdentifier: "TestABC--1234@^", targetItemType: .file)
		let itemToStore = GoogleDriveItem(cloudPath: CloudPath("/abc/shortcut"), identifier: "ShortcutIdentifier", itemType: .symlink, shortcut: shortcut)

		try cache.addOrUpdate(itemToStore)

		XCTAssertEqual(itemToStore, cache.get(itemToStore.cloudPath))
	}
}

class MicrosoftGraphIdentifierCacheTests: IdentifierCacheTests {
	override func makeCache() throws -> IdentifierCacheProbe {
		return try IdentifierCacheProbe { MicrosoftGraphItem(cloudPath: $0, identifier: "TestABC--\($1)@^", driveIdentifier: "Drive\($1)", itemType: $2) }
	}
}
