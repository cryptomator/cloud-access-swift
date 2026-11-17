//
//  VaultFormat6ShortenedNameCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct VaultFormat6ShortenedNameCacheTests {
		let vaultPath = CloudPath("/foo/bar")
		let cache: VaultFormat6ShortenedNameCache

		init() throws {
			self.cache = try VaultFormat6ShortenedNameCache(vaultPath: vaultPath)
		}

		@Test
		func testGetCached() throws {
			let shortenedName = "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng"
			let originalName = String(repeating: "a", count: 130)

			try cache.addToCache(shortenedName, originalName: originalName)

			#expect(try originalName == cache.getCached(shortenedName))
		}

		@Test
		func getShortenedPath1() {
			let longName = String(repeating: "a", count: 130)
			let originalPath = CloudPath("/foo/bar/d/2/30/\(longName)")
			let shortened = cache.getShortenedPath(originalPath)

			#expect(shortened.cloudPath.path == "/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng")
			#expect(shortened.pointsToLNG)
		}

		@Test
		func getShortenedPath2() {
			let originalPath = CloudPath("/foo/bar/d/2/30")
			let shortened = cache.getShortenedPath(originalPath)

			#expect(shortened.cloudPath.path == "/foo/bar/d/2/30")
			#expect(!shortened.pointsToLNG)
		}

		@Test
		func testGetOriginalPath() async throws {
			let shortened = CloudPath("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng")

			let longName = String(repeating: "a", count: 130)

			let original = try await cache.getOriginalPath(shortened) { lngFileName in
				#expect(lngFileName == "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng")
				return Data(longName.utf8)
			}
			#expect(original.path == "/foo/bar/d/2/30/\(longName)")
		}

		@Test
		func getOriginalPathWithNonUTF8Name() async {
			let shortened = CloudPath("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng")

			await #expect(throws: VaultFormatError.invalidNameFile) {
				try await cache.getOriginalPath(shortened) { _ in
					return Data([0xFF, 0xFE])
				}
			}
		}

		/// A name file is the cloud's to write, so a name that would redirect the inflated path is rejected and not cached.
		@Test
		func getOriginalPathWithNameThatIsNoSinglePathComponent() async throws {
			let shortened = CloudPath("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng")

			for name in ["../x", "a/b", ".", ""] {
				await #expect(throws: VaultFormatError.invalidNameFile, "\(name)") {
					try await cache.getOriginalPath(shortened) { _ in
						return Data(name.utf8)
					}
				}
			}
			let longName = String(repeating: "a", count: 130)
			let original = try await cache.getOriginalPath(shortened) { _ in
				return Data(longName.utf8)
			}
			#expect(original.path == "/foo/bar/d/2/30/\(longName)")
		}

		/// The inflated path is shortened again to address the item, so a name file holding the name of another item is rejected and not cached.
		@Test
		func getOriginalPathWithNameOfAnotherShortenedName() async throws {
			let shortened = CloudPath("/foo/bar/d/2/30/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng")
			let otherLongName = String(repeating: "file4", count: 26) // 2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng

			await #expect(throws: VaultFormatError.invalidNameFile) {
				try await cache.getOriginalPath(shortened) { _ in
					return Data(otherLongName.utf8)
				}
			}
			let longName = String(repeating: "a", count: 130)
			let original = try await cache.getOriginalPath(shortened) { _ in
				return Data(longName.utf8)
			}
			#expect(original.path == "/foo/bar/d/2/30/\(longName)")
		}

		/// The path of a name file is built from the first characters of the listed name, so a name that isn't 32 Base32 characters followed by `.lng` is rejected before its name file is loaded.
		@Test
		func getOriginalPathWithNameThatIsNoDeflatedName() async {
			for name in ["..AB.lng", "....lng", "AB...lng", ".lng", "shortened.lng", "4hgug7wd5cta3m2odukqut6hhcbnqo2b.lng", "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2.lng", "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B1.lng", "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng.lng", "4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2\u{C4}.lng"] {
				await #expect(throws: VaultFormatError.invalidNameFile, "\(name)") {
					try await cache.getOriginalPath(CloudPath("/foo/bar/d/2/30/\(name)")) { _ in
						Issue.record("unexpected name file lookup for \(name)")
						return Data("loooong".utf8)
					}
				}
			}
		}

		@Test
		func testDeflatePath() {
			let originalPath = CloudPath("/foo/bar/d/2/30/loooooong")
			let shortened = cache.deflatePath(originalPath, with: "short.lng")

			#expect(shortened.path == "/foo/bar/d/2/30/short.lng")
		}
	}
}
