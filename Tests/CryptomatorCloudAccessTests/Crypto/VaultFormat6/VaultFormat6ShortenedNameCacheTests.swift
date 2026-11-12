//
//  VaultFormat6ShortenedNameCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
@testable import CryptomatorCloudAccessCore

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

	func testGetShortenedPath1() {
		let longName = String(repeating: "a", count: 130)
		let originalPath = CloudPath("/foo/bar/d/2/30/\(longName)")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertEqual("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng", shortened.cloudPath.path)
		XCTAssertTrue(shortened.pointsToLNG)
	}

	func testGetShortenedPath2() {
		let originalPath = CloudPath("/foo/bar/d/2/30")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertEqual("/foo/bar/d/2/30", shortened.cloudPath.path)
		XCTAssertFalse(shortened.pointsToLNG)
	}

	func testGetOriginalPath() async throws {
		let shortened = CloudPath("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng")

		let longName = String(repeating: "a", count: 130)

		let original = try await cache.getOriginalPath(shortened) { lngFileName in
			XCTAssertEqual("4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng", lngFileName)
			return Data(longName.utf8)
		}
		XCTAssertEqual("/foo/bar/d/2/30/\(longName)", original.path)
	}

	func testGetOriginalPathWithNonUTF8Name() async {
		let shortened = CloudPath("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng")

		await XCTAssertThrowsErrorAsync(try await cache.getOriginalPath(shortened) { _ in
			return Data([0xFF, 0xFE])
		}) { error in
			XCTAssertEqual(.invalidNameFile, error as? VaultFormatError)
		}
	}

	/// A name file is the cloud's to write, so a name that would redirect the inflated path is rejected and not cached.
	func testGetOriginalPathWithNameThatIsNoSinglePathComponent() async throws {
		let shortened = CloudPath("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng")

		for name in ["../x", "a/b", ".", ""] {
			await XCTAssertThrowsErrorAsync(try await cache.getOriginalPath(shortened) { _ in
				return Data(name.utf8)
			}, name) { error in
				XCTAssertEqual(.invalidNameFile, error as? VaultFormatError, name)
			}
		}
		let longName = String(repeating: "a", count: 130)
		let original = try await cache.getOriginalPath(shortened) { _ in
			return Data(longName.utf8)
		}
		XCTAssertEqual("/foo/bar/d/2/30/\(longName)", original.path)
	}

	/// The inflated path is shortened again to address the item, so a name file holding the name of another item is rejected and not cached.
	func testGetOriginalPathWithNameOfAnotherShortenedName() async throws {
		let shortened = CloudPath("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng")
		let otherLongName = String(repeating: "file4", count: 26) // 2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng

		await XCTAssertThrowsErrorAsync(try await cache.getOriginalPath(shortened) { _ in
			return Data(otherLongName.utf8)
		}) { error in
			XCTAssertEqual(.invalidNameFile, error as? VaultFormatError)
		}
		let longName = String(repeating: "a", count: 130)
		let original = try await cache.getOriginalPath(shortened) { _ in
			return Data(longName.utf8)
		}
		XCTAssertEqual("/foo/bar/d/2/30/\(longName)", original.path)
	}

	/// The path of a name file is built from the first characters of the listed name, so a name that isn't 32 Base32 characters followed by `.lng` is rejected before its name file is loaded.
	func testGetOriginalPathWithNameThatIsNoDeflatedName() async {
		for name in ["..AB.lng", "....lng", "AB...lng", ".lng", "shortened.lng", "4hgug7wd5cta3m2odukqut6hhcbnqo2b.lng", "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2.lng", "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B1.lng", "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng.lng", "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2\u{C4}.lng"] {
			await XCTAssertThrowsErrorAsync(try await cache.getOriginalPath(CloudPath("/foo/bar/d/2/30/\(name)")) { _ in
				XCTFail("unexpected name file lookup for \(name)")
				return Data("loooong".utf8)
			}, name) { error in
				XCTAssertEqual(.invalidNameFile, error as? VaultFormatError, name)
			}
		}
	}

	func testDeflatePath() {
		let originalPath = CloudPath("/foo/bar/d/2/30/loooooong")
		let shortened = cache.deflatePath(originalPath, with: "short.lng")

		XCTAssertEqual("/foo/bar/d/2/30/short.lng", shortened.path)
	}
}
