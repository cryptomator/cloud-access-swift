//
//  IdentifierCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 22.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import Testing
@testable import CryptomatorCloudAccessCore

/// The cache of one item type, with the items built from a path, a number for the identifier and an item type.
struct IdentifierCacheProbe {
	let itemType: Any.Type
	let add: (_ path: String, _ identifier: Int, _ itemType: CloudItemType) throws -> Void
	let invalidate: (_ path: String) throws -> Void
	let contains: (_ path: String, _ identifier: Int, _ itemType: CloudItemType) -> Bool
	let containsNothing: (_ path: String) -> Bool
	let containsRootItem: () -> Bool

	init<Item: IdentifierCacheItem>(makeItem: @escaping (_ cloudPath: CloudPath, _ identifier: Int, _ itemType: CloudItemType) -> Item) throws {
		let cache = try IdentifierCache<Item>()
		self.itemType = Item.self
		self.add = { try cache.addOrUpdate(makeItem(CloudPath($0), $1, $2)) }
		self.invalidate = { try cache.invalidate(makeItem(CloudPath($0), 0, .folder)) }
		self.contains = { cache.get(CloudPath($0)) == makeItem(CloudPath($0), $1, $2) }
		self.containsNothing = { cache.get(CloudPath($0)) == nil }
		self.containsRootItem = { cache.get(CloudPath("/")) == Item.rootItem }
	}
}

/// The item types whose caches the tests run for.
enum CacheKind: CaseIterable, CustomTestStringConvertible {
	case box
	case pCloud
	case googleDrive
	case microsoftGraph

	var testDescription: String {
		return "\(self)"
	}

	func makeProbe() throws -> IdentifierCacheProbe {
		switch self {
		case .box:
			return try IdentifierCacheProbe { BoxItem(cloudPath: $0, identifier: String($1), itemType: $2) }
		case .pCloud:
			return try IdentifierCacheProbe { PCloudItem(cloudPath: $0, identifier: UInt64($1), itemType: $2) }
		case .googleDrive:
			return try IdentifierCacheProbe { GoogleDriveItem(cloudPath: $0, identifier: "TestABC--\($1)@^", itemType: $2, shortcut: nil) }
		case .microsoftGraph:
			return try IdentifierCacheProbe { MicrosoftGraphItem(cloudPath: $0, identifier: "TestABC--\($1)@^", driveIdentifier: "Drive\($1)", itemType: $2, isRemoteItem: false) }
		}
	}
}

extension UnitTests {
	struct IdentifierCacheTests {
		@Test(arguments: CacheKind.allCases)
		func probeCachesItemTypeOfKind(kind: CacheKind) throws {
			let expectedItemType: Any.Type = switch kind {
			case .box:
				BoxItem.self
			case .pCloud:
				PCloudItem.self
			case .googleDrive:
				GoogleDriveItem.self
			case .microsoftGraph:
				MicrosoftGraphItem.self
			}
			let itemType = try kind.makeProbe().itemType
			#expect(ObjectIdentifier(itemType) == ObjectIdentifier(expectedItemType), "\(itemType)")
		}

		@Test(arguments: CacheKind.allCases)
		func rootItemIsCachedAtStart(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			#expect(cache.containsRootItem())
		}

		@Test(arguments: CacheKind.allCases)
		func addAndGetForFileCloudPath(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			try cache.add("/abc/test.txt", 1234, .file)

			#expect(cache.contains("/abc/test.txt", 1234, .file))
		}

		@Test(arguments: CacheKind.allCases)
		func addAndGetForFolderCloudPath(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			try cache.add("/abc/test--a-", 1234, .folder)

			#expect(cache.contains("/abc/test--a-", 1234, .folder))
		}

		@Test(arguments: CacheKind.allCases)
		func updateWithDifferentItemRemovesSubPaths(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			try cache.add("/foo", 123, .folder)
			try cache.add("/foo/bar", 234, .file)
			try cache.add("/foo bar", 345, .folder)

			try cache.add("/foo", 567, .folder)

			#expect(cache.contains("/foo", 567, .folder))
			#expect(cache.containsNothing("/foo/bar"))
			#expect(cache.contains("/foo bar", 345, .folder))
		}

		@Test(arguments: CacheKind.allCases)
		func updateWithEqualItemKeepsSubPaths(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			try cache.add("/foo", 123, .folder)
			try cache.add("/foo/bar", 234, .file)

			try cache.add("/foo", 123, .folder)

			#expect(cache.contains("/foo/bar", 234, .file))
		}

		@Test(arguments: CacheKind.allCases)
		func invalidateIncludingSubPaths(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			try cache.add("/foo", 123, .folder)
			try cache.add("/foo/bar", 234, .folder)
			try cache.add("/foo/baz", 345, .folder)
			try cache.add("/bar/foo", 456, .folder)

			try cache.invalidate("/foo")

			#expect(cache.containsNothing("/foo"))
			#expect(cache.containsNothing("/foo/bar"))
			#expect(cache.containsNothing("/foo/baz"))
			#expect(cache.contains("/bar/foo", 456, .folder))
		}

		@Test(arguments: CacheKind.allCases)
		func invalidateMatchesPathsLiterally(kind: CacheKind) throws {
			let cases: [(invalidated: String, kept: [String])] = [
				("/a", ["/ab", "/A/x", "/a_b", "/a.", "/a0"]),
				("/a_b", ["/aXb/x"]),
				("/a%", ["/abc"])
			]
			for (invalidated, kept) in cases {
				let cache = try kind.makeProbe()
				for path in [invalidated, invalidated + "/x"] + kept {
					try cache.add(path, 1, .folder)
				}

				try cache.invalidate(invalidated)

				#expect(cache.containsNothing(invalidated), "\(invalidated)")
				#expect(cache.containsNothing(invalidated + "/x"), "\(invalidated)")
				for path in kept {
					#expect(cache.contains(path, 1, .folder), "\(path) after invalidating \(invalidated)")
				}
			}
		}

		@Test(arguments: CacheKind.allCases)
		func invalidateRootRemovesEveryItem(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			try cache.add("/foo/bar", 123, .folder)

			try cache.invalidate("/")

			#expect(cache.containsNothing("/"))
			#expect(cache.containsNothing("/foo/bar"))
		}

		@Test(arguments: CacheKind.allCases)
		func getAfterInvalidatingDifferentIdentifier(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			try cache.add("/abc/test--a-", 1234, .folder)
			try cache.add("/test/AAAAAAAAAAAA/test.txt", 9012, .folder)

			try cache.invalidate("/abc/test--a-")

			#expect(cache.containsNothing("/abc/test--a-"))
			#expect(cache.contains("/test/AAAAAAAAAAAA/test.txt", 9012, .folder))
		}

		@Test(arguments: CacheKind.allCases)
		func invalidateForNonExistentCloudPath(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			#expect(cache.containsNothing("/abc/test--a-"))

			try cache.invalidate("/abc/test--a-")
		}

		@Test
		func addAndGetForShortcut() throws {
			let cache = try IdentifierCache<GoogleDriveItem>()
			let shortcut = GoogleDriveShortcut(targetIdentifier: "TestABC--1234@^", targetItemType: .file)
			let itemToStore = GoogleDriveItem(cloudPath: CloudPath("/abc/shortcut"), identifier: "ShortcutIdentifier", itemType: .symlink, shortcut: shortcut)

			try cache.addOrUpdate(itemToStore)

			#expect(itemToStore == cache.get(itemToStore.cloudPath))
		}

		@Test(arguments: [("0123456789abcdef", "0123456789ABCDEF"), ("0123456789abcdef", "123456789ABCDEF")])
		func updateWithOtherSpellingOfPersonalDriveIdentifierKeepsSubPaths(driveIdentifier: String, otherSpelling: String) throws {
			let cache = try IdentifierCache<MicrosoftGraphItem>()
			let child = MicrosoftGraphItem(cloudPath: CloudPath("/foo/bar"), identifier: "B", driveIdentifier: driveIdentifier, itemType: .file, isRemoteItem: false)
			try cache.addOrUpdate(MicrosoftGraphItem(cloudPath: CloudPath("/foo"), identifier: "F", driveIdentifier: driveIdentifier, itemType: .folder, isRemoteItem: false))
			try cache.addOrUpdate(child)

			try cache.addOrUpdate(MicrosoftGraphItem(cloudPath: CloudPath("/foo"), identifier: "F", driveIdentifier: otherSpelling, itemType: .folder, isRemoteItem: false))

			#expect(cache.get(child.cloudPath) == child)
		}

		@Test(arguments: [("abc", "def"), ("b!Ab", "b!ab"), ("0123456789abcdef", "0123456789abcdee"), ("0123456789abcdef", "+123456789abcdef"), ("0123456789abcdef", nil)] as [(String, String?)])
		func updateWithOtherDriveOfSameIdentifierRemovesSubPaths(driveIdentifier: String, otherDriveIdentifier: String?) throws {
			let cache = try IdentifierCache<MicrosoftGraphItem>()
			try cache.addOrUpdate(MicrosoftGraphItem(cloudPath: CloudPath("/foo"), identifier: "F", driveIdentifier: driveIdentifier, itemType: .folder, isRemoteItem: false))
			try cache.addOrUpdate(MicrosoftGraphItem(cloudPath: CloudPath("/foo/bar"), identifier: "B", driveIdentifier: driveIdentifier, itemType: .file, isRemoteItem: false))

			try cache.addOrUpdate(MicrosoftGraphItem(cloudPath: CloudPath("/foo"), identifier: "F", driveIdentifier: otherDriveIdentifier, itemType: .folder, isRemoteItem: false))

			#expect(cache.get(CloudPath("/foo/bar")) == nil)
		}

		@Test
		func updateWithRemoteItemOfSameIdentifierRemovesSubPaths() throws {
			let cache = try IdentifierCache<MicrosoftGraphItem>()
			try cache.addOrUpdate(MicrosoftGraphItem(cloudPath: CloudPath("/foo"), identifier: "F", driveIdentifier: "abc", itemType: .folder, isRemoteItem: false))
			try cache.addOrUpdate(MicrosoftGraphItem(cloudPath: CloudPath("/foo/bar"), identifier: "B", driveIdentifier: "abc", itemType: .file, isRemoteItem: false))

			try cache.addOrUpdate(MicrosoftGraphItem(cloudPath: CloudPath("/foo"), identifier: "F", driveIdentifier: "abc", itemType: .folder, isRemoteItem: true))

			#expect(cache.get(CloudPath("/foo/bar")) == nil)
		}

		@Test
		func updateWithShortcutOfSameIdentifierRemovesSubPaths() throws {
			let cache = try IdentifierCache<GoogleDriveItem>()
			try cache.addOrUpdate(GoogleDriveItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder, shortcut: nil))
			try cache.addOrUpdate(GoogleDriveItem(cloudPath: CloudPath("/foo/bar"), identifier: "B", itemType: .file, shortcut: nil))

			try cache.addOrUpdate(GoogleDriveItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder, shortcut: GoogleDriveShortcut(targetIdentifier: "T", targetItemType: .folder)))

			#expect(cache.get(CloudPath("/foo/bar")) == nil)
		}

		@Test
		func resolvePathCachesLookedUpItems() async throws {
			let cache = try IdentifierCache<BoxItem>()
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder))

			let item = try await cache.resolvePath(forItemAt: CloudPath("/foo/bar/baz")) { name, parentItem in
				BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: "\(parentItem.identifier)/\(name)", itemType: .folder)
			}

			#expect(item.identifier == "F/bar/baz")
			#expect(cache.get(CloudPath("/foo/bar"))?.identifier == "F/bar")
			#expect(cache.get(item.cloudPath) == item)
		}

		@Test
		func resolvePathLooksUpAgainInReplacedFolder() async throws {
			let cache = try IdentifierCache<BoxItem>()
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder))
			var lookups: [String] = []

			let item = try await cache.resolvePath(forItemAt: CloudPath("/foo/bar/baz")) { name, parentItem in
				lookups.append("\(parentItem.identifier)/\(name)")
				if lookups.count == 1 {
					try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "G", itemType: .folder))
				}
				return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: "\(parentItem.identifier)/\(name)", itemType: .folder)
			}

			#expect(lookups == ["F/bar", "G/bar", "G/bar/baz"])
			#expect(item.identifier == "G/bar/baz")
			#expect(cache.get(CloudPath("/foo/bar"))?.identifier == "G/bar")
			#expect(cache.get(item.cloudPath) == item)
		}

		@Test
		func resolvePathLooksUpAgainFromAncestorOfInvalidatedFolder() async throws {
			let cache = try IdentifierCache<BoxItem>()
			let folder = BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder)
			try cache.addOrUpdate(folder)
			var lookups: [String] = []

			let item = try await cache.resolvePath(forItemAt: CloudPath("/foo/bar")) { name, parentItem in
				lookups.append("\(parentItem.identifier)/\(name)")
				if lookups.count == 1 {
					try cache.invalidate(folder)
				}
				return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: "\(parentItem.identifier)/\(name)", itemType: .folder)
			}

			#expect(lookups == ["F/bar", "0/foo", "0/foo/bar"])
			#expect(cache.get(CloudPath("/foo"))?.identifier == "0/foo")
			#expect(cache.get(item.cloudPath) == item)
		}

		@Test
		func resolvePathThrowsIfFolderChangesDuringBothAttempts() async throws {
			let cache = try IdentifierCache<BoxItem>()
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder))
			var lookupCount = 0

			await #expect(throws: BoxError.inconsistentCache) {
				try await cache.resolvePath(forItemAt: CloudPath("/foo/bar")) { name, parentItem in
					lookupCount += 1
					try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "F\(lookupCount)", itemType: .folder))
					return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: name, itemType: .file)
				}
			}
			#expect(lookupCount == 2)
			#expect(cache.get(CloudPath("/foo/bar")) == nil)
		}

		/// Removing the last component of such a path never reaches the root, so it throws before any lookup instead of resolving to an item it doesn't name.
		@Test(arguments: ["/../x", "/..", "a/b", "x"])
		func resolvePathOfPathThatNeverReachesRootThrowsWithoutLookup(path: String) async throws {
			let cache = try IdentifierCache<BoxItem>()
			var lookupCount = 0

			await #expect(throws: CloudProviderError.itemNotFound) {
				try await cache.resolvePath(forItemAt: CloudPath(path)) { name, parentItem in
					lookupCount += 1
					return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: name, itemType: .folder)
				}
			}
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) {
				try await cache.resolveParentPath(forItemAt: CloudPath(path).appendingPathComponent("y")) { name, parentItem in
					lookupCount += 1
					return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: name, itemType: .folder)
				}
			}
			#expect(lookupCount == 0)
		}

		/// An item left below an empty slot by a write without the parent check wasn't cached below the item now saved there.
		@Test
		func saveIntoEmptySlotRemovesItemsLeftBelowIt() throws {
			let cache = try IdentifierCache<BoxItem>()
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo/bar"), identifier: "B", itemType: .file))

			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder))

			#expect(cache.get(CloudPath("/foo/bar")) == nil)
		}

		/// A write without the parent check can cache a folder after the item of its ancestor was removed, so the folder and the items below it may belong to a folder that moved elsewhere.
		@Test
		func itemsBelowMissingAncestorAreNeitherConnectedNorStartingPoint() async throws {
			let cache = try IdentifierCache<BoxItem>()
			let orphan = BoxItem(cloudPath: CloudPath("/gone/sub"), identifier: "S", itemType: .folder)
			try cache.addOrUpdate(orphan)
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/gone/sub/x"), identifier: "S/x", itemType: .file))
			var lookups: [String] = []

			#expect(cache.isConnected(BoxItem.rootItem))
			#expect(!cache.isConnected(orphan))
			#expect(cache.itemWithParent(at: CloudPath("/gone/sub/x")) == nil)
			#expect(try !cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/gone/sub/y"), identifier: "S/y", itemType: .file), ifStillBelow: orphan))
			#expect(cache.get(CloudPath("/gone/sub/y")) == nil)
			let item = try await cache.resolvePath(forItemAt: CloudPath("/gone/sub/x")) { name, parentItem in
				lookups.append("\(parentItem.identifier)/\(name)")
				return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: "\(parentItem.identifier)/\(name)", itemType: name == "x" ? .file : .folder)
			}

			#expect(lookups == ["0/gone", "0/gone/sub", "0/gone/sub/x"])
			#expect(item.identifier == "0/gone/sub/x")
			#expect(cache.itemWithParent(at: item.cloudPath)?.parent.identifier == "0/gone/sub")
		}

		/// The pair is read only if every item from the root to the path is cached, so a shorter connected part of the path is never taken for the item and its folder.
		@Test
		func itemWithParentNeedsEveryItemOnPath() throws {
			let cache = try IdentifierCache<BoxItem>()
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder))
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo/gone/x"), identifier: "X", itemType: .file))

			#expect(cache.itemWithParent(at: CloudPath("/foo/gone/x")) == nil)
			#expect(cache.itemWithParent(at: CloudPath("/foo"))?.parent == BoxItem.rootItem)
		}

		/// A file has no items below it, so an item cached below one, e.g., by a listing that is still running when another client replaces the folder with a file, wasn't found there.
		@Test
		func itemsBelowItemThatIsNoFolderAreNotConnected() throws {
			let cache = try IdentifierCache<BoxItem>()
			let subfolder = BoxItem(cloudPath: CloudPath("/file/sub"), identifier: "S", itemType: .folder)
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/file"), identifier: "F", itemType: .file))
			try cache.addOrUpdate(subfolder)

			#expect(!cache.isConnected(subfolder))
			#expect(cache.itemWithParent(at: subfolder.cloudPath) == nil)
			#expect(try !cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/file/sub/x"), identifier: "S/x", itemType: .file), ifStillBelow: subfolder))
		}

		/// An item that another write replaced at its path is no longer connected, although an item is cached there.
		@Test
		func replacedItemIsNotConnected() throws {
			let cache = try IdentifierCache<BoxItem>()
			let folder = BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder)
			try cache.addOrUpdate(folder)

			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "G", itemType: .folder))

			#expect(!cache.isConnected(folder))
		}

		@Test
		func conditionalAddWritesOnlyBelowStillCachedParent() throws {
			let cache = try IdentifierCache<BoxItem>()
			let parentItem = BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder)
			try cache.addOrUpdate(parentItem)
			let firstChild = BoxItem(cloudPath: CloudPath("/foo/a"), identifier: "A", itemType: .file)
			let secondChild = BoxItem(cloudPath: CloudPath("/foo/b"), identifier: "B", itemType: .file)

			let wroteFirstChild = try cache.addOrUpdate(firstChild, ifStillBelow: parentItem)
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "G", itemType: .folder))
			let wroteSecondChild = try cache.addOrUpdate(secondChild, ifStillBelow: parentItem)

			#expect(wroteFirstChild)
			#expect(!wroteSecondChild)
			#expect(cache.get(secondChild.cloudPath) == nil)
		}
	}

	struct IdentifierCacheDatabaseTests {
		@Test
		func databaseFileIsDeletedWithCache() throws {
			var cache: IdentifierCache<PCloudItem>? = try IdentifierCache<PCloudItem>()
			let databaseURL = try #require(cache).directoryURL.appendingPathComponent("identifiers.sqlite")

			#expect(FileManager.default.fileExists(atPath: databaseURL.path))
			#expect(try databaseURL.path.hasPrefix(ProcessTemporaryDirectory.shared.directoryURL().path))
			cache = nil
			#expect(!FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path))
		}

		@Test
		func databaseNeedsNoDurability() throws {
			let cache = try IdentifierCache<PCloudItem>()

			let (journalMode, synchronous, cacheSize) = try cache.dbQueue.read { db in
				try (String.fetchOne(db, sql: "PRAGMA journal_mode"), Int.fetchOne(db, sql: "PRAGMA synchronous"), Int.fetchOne(db, sql: "PRAGMA cache_size"))
			}

			#expect(journalMode == "wal")
			#expect(synchronous == 0)
			#expect(cacheSize == -500)
		}

		@Test
		func invalidateRemovesLargeSubtree() throws {
			let cache = try IdentifierCache<PCloudItem>()
			for identifier in 1 ... 2000 {
				try cache.addOrUpdate(PCloudItem(cloudPath: CloudPath("/foo/\(identifier)"), identifier: UInt64(identifier), itemType: .file))
			}
			try cache.addOrUpdate(PCloudItem(cloudPath: CloudPath("/bar"), identifier: 1, itemType: .folder))

			try cache.invalidate(PCloudItem(cloudPath: CloudPath("/foo"), identifier: 0, itemType: .folder))

			let itemCount = try cache.dbQueue.read { db in
				try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(PCloudItem.databaseTableName)")
			}
			#expect(itemCount == 2)
			#expect(cache.get(CloudPath("/bar")) != nil)
		}
	}
}
