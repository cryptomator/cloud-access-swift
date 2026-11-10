//
//  VaultFormat7ShortenedNameCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultFormat7ShortenedNameCacheTests: XCTestCase {
	let vaultPath = CloudPath("/foo/bar")
	var cache: VaultFormat7ShortenedNameCache!

	override func setUpWithError() throws {
		cache = try VaultFormat7ShortenedNameCache(vaultPath: vaultPath, threshold: 220)
	}

	func testGetCached() throws {
		let shortenedName = "-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
		let originalName = "\(String(repeating: "a", count: 217)).c9r"

		try cache.addToCache(shortenedName, originalName: originalName)

		XCTAssertEqual(originalName, try cache.getCached(shortenedName))
	}

	func testGetShortenedPath1() {
		let longName = String(repeating: "a", count: 217) // 221 chars when including .c9r
		let originalPath = CloudPath("/foo/bar/d/2/30/\(longName).c9r")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertNotNil(shortened.c9sDir)
		XCTAssertEqual("\(longName).c9r", shortened.c9sDir?.originalName)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", shortened.c9sDir?.cloudPath.path)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", shortened.cloudPath.path)
		XCTAssertTrue(shortened.pointsToC9S)
	}

	func testGetShortenedPath2() {
		let longName = String(repeating: "a", count: 217) // 221 chars when including .c9r
		let originalPath = CloudPath("/foo/bar/d/2/30/\(longName).c9r/dir.c9r")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertNotNil(shortened.c9sDir)
		XCTAssertEqual("\(longName).c9r", shortened.c9sDir?.originalName)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", shortened.c9sDir?.cloudPath.path)
		XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r", shortened.cloudPath.path)
		XCTAssertFalse(shortened.pointsToC9S)
	}

	func testGetShortenedPath3() {
		let originalPath = CloudPath("/foo/bar/d/2/30")
		let shortened = cache.getShortenedPath(originalPath)

		XCTAssertNil(shortened.c9sDir)
		XCTAssertEqual("/foo/bar/d/2/30", shortened.cloudPath.path)
		XCTAssertFalse(shortened.pointsToC9S)
	}

	func testGetOriginalPath1() async throws {
		let shortened = CloudPath("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
		let longName = "\(String(repeating: "a", count: 217)).c9r"

		let original = try await cache.getOriginalPath(shortened) { cloudPath in
			XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", cloudPath.path)
			return Data(longName.utf8)
		}
		XCTAssertEqual("/foo/bar/d/2/30/\(longName)", original.path)
	}

	func testGetOriginalPath2() async throws {
		let shortened = CloudPath("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r")
		let longName = "\(String(repeating: "a", count: 217)).c9r"

		let original = try await cache.getOriginalPath(shortened) { cloudPath in
			XCTAssertEqual("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", cloudPath.path)
			return Data(longName.utf8)
		}
		XCTAssertEqual("/foo/bar/d/2/30/\(longName)/dir.c9r", original.path)
	}

	/// The cache counts the path's segments like `CloudPath` counts its components, also where a slash and a combining mark are one `Character`.
	func testShortenedAndOriginalPathBelowVaultPathWithCombiningMark() async throws {
		let cache = try VaultFormat7ShortenedNameCache(vaultPath: CloudPath("/foo/\u{301}bar"), threshold: 220)
		let longName = String(repeating: "a", count: 217)

		// Inflates before shortening, because shortening caches the name, and a cached name isn't loaded.
		let original = try await cache.getOriginalPath(CloudPath("/foo/\u{301}bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r")) { cloudPath in
			XCTAssertEqual("/foo/\u{301}bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", cloudPath.path)
			return Data("\(longName).c9r".utf8)
		}
		let shortened = cache.getShortenedPath(CloudPath("/foo/\u{301}bar/d/2/30/\(longName).c9r/dir.c9r"))

		XCTAssertEqual("/foo/\u{301}bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r", shortened.cloudPath.path)
		XCTAssertEqual("/foo/\u{301}bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s", shortened.c9sDir?.cloudPath.path)
		XCTAssertEqual("/foo/\u{301}bar/d/2/30/\(longName).c9r/dir.c9r", original.path)
	}

	func testGetOriginalPathWithNonUTF8Name() async {
		let shortened = CloudPath("/foo/bar/d/2/30/shortened.c9s")

		await XCTAssertThrowsErrorAsync(try await cache.getOriginalPath(shortened) { _ in
			return Data([0xFF, 0xFE])
		}) { error in
			XCTAssertEqual(.invalidNameFile, error as? VaultFormatError)
		}
	}

	/// A name file is the cloud's to write, so a name that would redirect the inflated path is rejected and not cached.
	func testGetOriginalPathWithNameThatIsNoSinglePathComponent() async throws {
		let shortened = CloudPath("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")

		for name in ["../x.c9r", "a/b", ".", ""] {
			await XCTAssertThrowsErrorAsync(try await cache.getOriginalPath(shortened) { _ in
				return Data(name.utf8)
			}, name) { error in
				XCTAssertEqual(.invalidNameFile, error as? VaultFormatError, name)
			}
		}
		let longName = "\(String(repeating: "a", count: 217)).c9r"
		let original = try await cache.getOriginalPath(shortened) { _ in
			return Data(longName.utf8)
		}
		XCTAssertEqual("/foo/bar/d/2/30/\(longName)", original.path)
	}

	/// The inflated path is shortened again to address the item, so a name file holding the name of another item is rejected and not cached.
	func testGetOriginalPathWithNameOfAnotherShortenedName() async throws {
		let shortened = CloudPath("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
		let otherLongName = "\(String(repeating: "file4", count: 44)).c9r" // 9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s

		await XCTAssertThrowsErrorAsync(try await cache.getOriginalPath(shortened) { _ in
			return Data(otherLongName.utf8)
		}) { error in
			XCTAssertEqual(.invalidNameFile, error as? VaultFormatError)
		}
		let longName = "\(String(repeating: "a", count: 217)).c9r"
		let original = try await cache.getOriginalPath(shortened) { _ in
			return Data(longName.utf8)
		}
		XCTAssertEqual("/foo/bar/d/2/30/\(longName)", original.path)
	}

	/// The listed name is compared byte by byte, so a name that differs from the hash only in case or padding, or that is merely canonically equivalent to it (U+212A KELVIN SIGN for `K`), is rejected.
	func testGetOriginalPathWithListedNameInAnotherSpelling() async {
		let longName = "\(String(repeating: "a", count: 217)).c9r"
		let otherLongName = "\(String(repeating: "file4", count: 44)).c9r" // 9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s
		let spellings = [
			"-R4LCVEMRSBH0DWUK2YFMOP9TCO=.c9s": longName,
			"-r4lcvemRsbH0dWuk2yfMOp9tco.c9s": longName,
			"9j5eV\u{212A}QZdTojV6zlbxhcCLD_8bs=.c9s": otherLongName
		]

		for (name, nameFileContent) in spellings {
			await XCTAssertThrowsErrorAsync(try await cache.getOriginalPath(CloudPath("/foo/bar/d/2/30/\(name)")) { _ in
				return Data(nameFileContent.utf8)
			}, name) { error in
				XCTAssertEqual(.invalidNameFile, error as? VaultFormatError, name)
			}
		}
	}

	func testDeflatePath1() {
		let originalPath = CloudPath("/foo/bar/d/2/30/loooooong.c9r/dir.c9r")
		let shortened = cache.deflatePath(originalPath, with: "short.c9s")

		XCTAssertEqual("/foo/bar/d/2/30/short.c9s/dir.c9r", shortened.path)
	}

	func testDeflatePath2() {
		let originalPath = CloudPath("/foo/bar/d/2/30/loooooong.c9r")
		let shortened = cache.deflatePath(originalPath, with: "short.c9s")

		XCTAssertEqual("/foo/bar/d/2/30/short.c9s", shortened.path)
	}

	func testDeflatePath3() {
		let originalPath = CloudPath("/foo/bar/d/2/30/loooooong.c9r/dir.c9r/baz")
		let shortened = cache.deflatePath(originalPath, with: "short.c9s")

		XCTAssertEqual("/foo/bar/d/2/30/short.c9s/dir.c9r/baz", shortened.path)
	}
}
