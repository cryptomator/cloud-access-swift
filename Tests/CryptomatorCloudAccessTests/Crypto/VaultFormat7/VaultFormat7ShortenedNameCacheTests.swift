//
//  VaultFormat7ShortenedNameCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct VaultFormat7ShortenedNameCacheTests {
		let vaultPath = CloudPath("/foo/bar")
		let cache: VaultFormat7ShortenedNameCache

		init() throws {
			self.cache = try VaultFormat7ShortenedNameCache(vaultPath: vaultPath, threshold: 220)
		}

		@Test
		func testGetCached() throws {
			let shortenedName = "-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s"
			let originalName = "\(String(repeating: "a", count: 217)).c9r"

			try cache.addToCache(shortenedName, originalName: originalName)

			#expect(try originalName == cache.getCached(shortenedName))
		}

		@Test
		func getShortenedPath1() {
			let longName = String(repeating: "a", count: 217) // 221 chars when including .c9r
			let originalPath = CloudPath("/foo/bar/d/2/30/\(longName).c9r")
			let shortened = cache.getShortenedPath(originalPath)

			#expect(shortened.c9sDir != nil)
			#expect(shortened.c9sDir?.originalName == "\(longName).c9r")
			#expect(shortened.c9sDir?.cloudPath.path == "/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
			#expect(shortened.cloudPath.path == "/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
			#expect(shortened.pointsToC9S)
		}

		@Test
		func getShortenedPath2() {
			let longName = String(repeating: "a", count: 217) // 221 chars when including .c9r
			let originalPath = CloudPath("/foo/bar/d/2/30/\(longName).c9r/dir.c9r")
			let shortened = cache.getShortenedPath(originalPath)

			#expect(shortened.c9sDir != nil)
			#expect(shortened.c9sDir?.originalName == "\(longName).c9r")
			#expect(shortened.c9sDir?.cloudPath.path == "/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
			#expect(shortened.cloudPath.path == "/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r")
			#expect(!shortened.pointsToC9S)
		}

		@Test
		func getShortenedPath3() {
			let originalPath = CloudPath("/foo/bar/d/2/30")
			let shortened = cache.getShortenedPath(originalPath)

			#expect(shortened.c9sDir == nil)
			#expect(shortened.cloudPath.path == "/foo/bar/d/2/30")
			#expect(!shortened.pointsToC9S)
		}

		@Test
		func getOriginalPath1() async throws {
			let shortened = CloudPath("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
			let longName = "\(String(repeating: "a", count: 217)).c9r"

			let original = try await cache.getOriginalPath(shortened) { cloudPath in
				#expect(cloudPath.path == "/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
				return Data(longName.utf8)
			}
			#expect(original.path == "/foo/bar/d/2/30/\(longName)")
		}

		@Test
		func getOriginalPath2() async throws {
			let shortened = CloudPath("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r")
			let longName = "\(String(repeating: "a", count: 217)).c9r"

			let original = try await cache.getOriginalPath(shortened) { cloudPath in
				#expect(cloudPath.path == "/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
				return Data(longName.utf8)
			}
			#expect(original.path == "/foo/bar/d/2/30/\(longName)/dir.c9r")
		}

		/// The cache counts the path's segments like `CloudPath` counts its components, also where a slash and a combining mark are one `Character`.
		@Test
		func shortenedAndOriginalPathBelowVaultPathWithCombiningMark() async throws {
			let cache = try VaultFormat7ShortenedNameCache(vaultPath: CloudPath("/foo/\u{301}bar"), threshold: 220)
			let longName = String(repeating: "a", count: 217)

			// Inflates before shortening, because shortening caches the name, and a cached name isn't loaded.
			let original = try await cache.getOriginalPath(CloudPath("/foo/\u{301}bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r")) { cloudPath in
				#expect(cloudPath.path == "/foo/\u{301}bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
				return Data("\(longName).c9r".utf8)
			}
			let shortened = cache.getShortenedPath(CloudPath("/foo/\u{301}bar/d/2/30/\(longName).c9r/dir.c9r"))

			#expect(shortened.cloudPath.path == "/foo/\u{301}bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s/dir.c9r")
			#expect(shortened.c9sDir?.cloudPath.path == "/foo/\u{301}bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
			#expect(original.path == "/foo/\u{301}bar/d/2/30/\(longName).c9r/dir.c9r")
		}

		@Test
		func getOriginalPathWithNonUTF8Name() async {
			let shortened = CloudPath("/foo/bar/d/2/30/shortened.c9s")

			await #expect(throws: VaultFormatError.invalidNameFile) {
				try await cache.getOriginalPath(shortened) { _ in
					return Data([0xFF, 0xFE])
				}
			}
		}

		/// A name file is the cloud's to write, so a name that would redirect the inflated path is rejected and not cached.
		@Test
		func getOriginalPathWithNameThatIsNoSinglePathComponent() async throws {
			let shortened = CloudPath("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")

			for name in ["../x.c9r", "a/b", ".", ""] {
				await #expect(throws: VaultFormatError.invalidNameFile, "\(name)") {
					try await cache.getOriginalPath(shortened) { _ in
						return Data(name.utf8)
					}
				}
			}
			let longName = "\(String(repeating: "a", count: 217)).c9r"
			let original = try await cache.getOriginalPath(shortened) { _ in
				return Data(longName.utf8)
			}
			#expect(original.path == "/foo/bar/d/2/30/\(longName)")
		}

		/// The inflated path is shortened again to address the item, so a name file holding the name of another item is rejected and not cached.
		@Test
		func getOriginalPathWithNameOfAnotherShortenedName() async throws {
			let shortened = CloudPath("/foo/bar/d/2/30/-r4lcvemRsbH0dWuk2yfMOp9tco=.c9s")
			let otherLongName = "\(String(repeating: "file4", count: 44)).c9r" // 9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s

			await #expect(throws: VaultFormatError.invalidNameFile) {
				try await cache.getOriginalPath(shortened) { _ in
					return Data(otherLongName.utf8)
				}
			}
			let longName = "\(String(repeating: "a", count: 217)).c9r"
			let original = try await cache.getOriginalPath(shortened) { _ in
				return Data(longName.utf8)
			}
			#expect(original.path == "/foo/bar/d/2/30/\(longName)")
		}

		/// A name that isn't longer than the threshold isn't shortened, so the inflated path would address another item than the listed `.c9s`. The name file is rejected even though its name hashes to the `.c9s` name.
		@Test
		func getOriginalPathWithNameNotLongerThanThreshold() async {
			let names = [
				"aB0uiw4R5k6IpZuizrdgRcaPckg=.c9s": "short.c9r",
				"795gAWf-P9tGGBt9EkGz9mKSGq0=.c9s": "\(String(repeating: "a", count: 216)).c9r" // exactly the threshold
			]

			for (shortenedName, name) in names {
				await #expect(throws: VaultFormatError.invalidNameFile, "\(shortenedName)") {
					try await cache.getOriginalPath(CloudPath("/foo/bar/d/2/30/\(shortenedName)")) { _ in
						return Data(name.utf8)
					}
				}
			}
		}

		/// The listed name is compared byte by byte, so a name that differs from the hash only in case or padding, or that is merely canonically equivalent to it (U+212A KELVIN SIGN for `K`), is rejected.
		@Test
		func getOriginalPathWithListedNameInAnotherSpelling() async {
			let longName = "\(String(repeating: "a", count: 217)).c9r"
			let otherLongName = "\(String(repeating: "file4", count: 44)).c9r" // 9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s
			let spellings = [
				"-R4LCVEMRSBH0DWUK2YFMOP9TCO=.c9s": longName,
				"-r4lcvemRsbH0dWuk2yfMOp9tco.c9s": longName,
				"9j5eV\u{212A}QZdTojV6zlbxhcCLD_8bs=.c9s": otherLongName
			]

			for (name, nameFileContent) in spellings {
				await #expect(throws: VaultFormatError.invalidNameFile, "\(name)") {
					try await cache.getOriginalPath(CloudPath("/foo/bar/d/2/30/\(name)")) { _ in
						return Data(nameFileContent.utf8)
					}
				}
			}
		}

		@Test
		func deflatePath1() {
			let originalPath = CloudPath("/foo/bar/d/2/30/loooooong.c9r/dir.c9r")
			let shortened = cache.deflatePath(originalPath, with: "short.c9s")

			#expect(shortened.path == "/foo/bar/d/2/30/short.c9s/dir.c9r")
		}

		@Test
		func deflatePath2() {
			let originalPath = CloudPath("/foo/bar/d/2/30/loooooong.c9r")
			let shortened = cache.deflatePath(originalPath, with: "short.c9s")

			#expect(shortened.path == "/foo/bar/d/2/30/short.c9s")
		}

		@Test
		func deflatePath3() {
			let originalPath = CloudPath("/foo/bar/d/2/30/loooooong.c9r/dir.c9r/baz")
			let shortened = cache.deflatePath(originalPath, with: "short.c9s")

			#expect(shortened.path == "/foo/bar/d/2/30/short.c9s/dir.c9r/baz")
		}
	}
}
