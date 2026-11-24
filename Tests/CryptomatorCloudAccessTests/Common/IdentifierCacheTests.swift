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

extension IdentifierCache {
	/// Seeds a row without any of the checks of a response's write.
	func addOrUpdate(_ item: Item) throws {
		try dbQueue.write { db in
			_ = try save(item, in: db)
		}
	}
}

/// The description of an item, which each probe builds as an item of its cache's type.
struct ProbeItem {
	let path: String
	let identifier: Int
	let itemType: CloudItemType

	static func file(_ path: String, _ identifier: Int) -> ProbeItem {
		return ProbeItem(path: path, identifier: identifier, itemType: .file)
	}

	static func folder(_ path: String, _ identifier: Int) -> ProbeItem {
		return ProbeItem(path: path, identifier: identifier, itemType: .folder)
	}
}

/// The cache of one item type, with the items built from a path, a number for the identifier and an item type.
struct IdentifierCacheProbe {
	let itemType: Any.Type
	let add: (_ path: String, _ identifier: Int, _ itemType: CloudItemType) throws -> Void
	let invalidate: (_ path: String) throws -> Void
	let contains: (_ path: String, _ identifier: Int, _ itemType: CloudItemType) -> Bool
	let containsNothing: (_ path: String) -> Bool
	let containsRootItem: () -> Bool
	let changeMark: () throws -> ChangeMark
	let writeRead: (_ item: ProbeItem, _ parent: ProbeItem, _ mark: ChangeMark) throws -> Bool
	let commitMutation: (_ item: ProbeItem, _ parent: ProbeItem, _ mark: ChangeMark) throws -> Void
	let commitMutationOfItemThatLeft: (_ item: ProbeItem, _ parent: ProbeItem) throws -> Void
	let commitMove: (_ source: ProbeItem, _ targetPath: String, _ target: ProbeItem?, _ parent: ProbeItem, _ mark: ChangeMark) throws -> Void
	let invalidateItem: (_ item: ProbeItem) throws -> Void

	init<Item: IdentifierCacheItem>(makeItem: @escaping (_ cloudPath: CloudPath, _ identifier: Int, _ itemType: CloudItemType) -> Item) throws {
		let cache = try IdentifierCache<Item>()
		let build: (ProbeItem) -> Item = { makeItem(CloudPath($0.path), $0.identifier, $0.itemType) }
		self.itemType = Item.self
		self.add = { try cache.addOrUpdate(makeItem(CloudPath($0), $1, $2)) }
		self.invalidate = { try cache.invalidate(makeItem(CloudPath($0), 0, .folder)) }
		self.contains = { cache.get(CloudPath($0)) == makeItem(CloudPath($0), $1, $2) }
		self.containsNothing = { cache.get(CloudPath($0)) == nil }
		self.containsRootItem = { cache.get(CloudPath("/")) == Item.rootItem }
		self.changeMark = { try cache.changeMark() }
		self.writeRead = { try cache.addOrUpdate(build($0), ifStillBelow: build($1), unchangedSince: $2).didSave }
		self.commitMutation = { try cache.commitMutation(build($0), ifStillBelow: build($1), unchangedSince: $2) }
		self.commitMutationOfItemThatLeft = { try cache.commitMutation(ofItemThatLeft: build($0), ifStillBelow: build($1)) }
		self.commitMove = { try cache.commitMove(of: build($0), to: CloudPath($1), as: $2.map(build), ifStillBelow: build($3), unchangedSince: $4) }
		self.invalidateItem = { try cache.invalidate(build($0)) }
	}

	func seed(_ items: ProbeItem...) throws {
		for item in items {
			try add(item.path, item.identifier, item.itemType)
		}
	}

	func holds(_ item: ProbeItem) -> Bool {
		return contains(item.path, item.identifier, item.itemType)
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

		/// An item left below an empty slot wasn't cached below the item now saved there.
		@Test
		func saveIntoEmptySlotRemovesItemsLeftBelowIt() throws {
			let cache = try IdentifierCache<BoxItem>()
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo/bar"), identifier: "B", itemType: .file))

			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder))

			#expect(cache.get(CloudPath("/foo/bar")) == nil)
		}

		/// A folder whose ancestor has no row, and the items below it, may belong to a folder that moved elsewhere.
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
			#expect(try !cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/gone/sub/y"), identifier: "S/y", itemType: .file), ifStillBelow: orphan, unchangedSince: cache.changeMark()).didSave)
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

		/// A file has no items below it, so an item cached below one wasn't found there.
		@Test
		func itemsBelowItemThatIsNoFolderAreNotConnected() throws {
			let cache = try IdentifierCache<BoxItem>()
			let subfolder = BoxItem(cloudPath: CloudPath("/file/sub"), identifier: "S", itemType: .folder)
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/file"), identifier: "F", itemType: .file))
			try cache.addOrUpdate(subfolder)

			#expect(!cache.isConnected(subfolder))
			#expect(cache.itemWithParent(at: subfolder.cloudPath) == nil)
			#expect(try !cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/file/sub/x"), identifier: "S/x", itemType: .file), ifStillBelow: subfolder, unchangedSince: cache.changeMark()).didSave)
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

			let wroteFirstChild = try cache.addOrUpdate(firstChild, ifStillBelow: parentItem, unchangedSince: cache.changeMark()).didSave
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "G", itemType: .folder))
			let wroteSecondChild = try cache.addOrUpdate(secondChild, ifStillBelow: parentItem, unchangedSince: cache.changeMark()).didSave

			#expect(wroteFirstChild)
			#expect(!wroteSecondChild)
			#expect(cache.get(secondChild.cloudPath) == nil)
		}

		// MARK: - Change Records

		private static let parent = ProbeItem.folder("/p", 100)

		@Test(arguments: CacheKind.allCases)
		func readIsRefusedAfterItsPathChangedAndLeavesCurrentRow(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let staleItem = ProbeItem.file("/p/a", 1)
			let replacement = ProbeItem.file("/p/a", 2)
			try cache.seed(parent, staleItem)
			let mark = try cache.changeMark()

			try cache.commitMutation(replacement, parent, cache.changeMark())

			#expect(try !cache.writeRead(staleItem, parent, mark))
			#expect(cache.holds(replacement))
		}

		@Test(arguments: CacheKind.allCases)
		func readIsRefusedAfterItsRowWasDeleted(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let staleItem = ProbeItem.file("/p/a", 1)
			try cache.seed(parent, staleItem)
			let mark = try cache.changeMark()

			try cache.invalidateItem(staleItem)

			#expect(try !cache.writeRead(staleItem, parent, mark))
			#expect(cache.containsNothing("/p/a"))
		}

		/// The item moved, so a late read must not cache it at a third name, whose path no mutation touched.
		@Test(arguments: CacheKind.allCases)
		func readOfMovedItemIsRefusedAtAnyPath(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let source = ProbeItem.file("/p/a", 1)
			try cache.seed(parent, source)
			let mark = try cache.changeMark()

			try cache.commitMove(source, "/p/b", .file("/p/b", 1), parent, cache.changeMark())

			#expect(try !cache.writeRead(.file("/p/c", 1), parent, mark))
			#expect(cache.containsNothing("/p/c"))
		}

		@Test(arguments: CacheKind.allCases)
		func changeOfSiblingRefusesNothing(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let item = ProbeItem.file("/p/a", 1)
			try cache.seed(parent)
			let mark = try cache.changeMark()

			try cache.commitMutation(.file("/p/b", 2), parent, mark)

			#expect(try cache.writeRead(item, parent, mark))
			#expect(cache.holds(item))
		}

		@Test(arguments: CacheKind.allCases)
		func markTakenAfterChangeIsAccepted(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let item = ProbeItem.file("/p/a", 1)
			try cache.seed(parent, item)
			try cache.invalidateItem(item)

			#expect(try cache.writeRead(item, parent, cache.changeMark()))
			#expect(cache.holds(item))
		}

		@Test(arguments: CacheKind.allCases)
		func refusedMutationLeavesPathUncachedBelowConnectedParent(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			try cache.seed(parent)
			let mark = try cache.changeMark()
			try cache.commitMutation(.file("/p/a", 2), parent, cache.changeMark())

			try cache.commitMutation(.file("/p/a", 3), parent, mark)

			#expect(cache.containsNothing("/p/a"))
		}

		@Test(arguments: CacheKind.allCases)
		func mutationBelowReplacedParentKeepsRowAtPath(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let currentItem = ProbeItem.file("/p/a", 7)
			try cache.seed(parent)
			let mark = try cache.changeMark()
			try cache.seed(.folder("/p", 101), currentItem)

			try cache.commitMutation(.file("/p/a", 3), parent, mark)

			#expect(cache.holds(currentItem))
		}

		/// The move's own records must not refuse its target, and the item's row at a third name must go.
		@Test(arguments: CacheKind.allCases)
		func moveEvictsEveryRowOfItemAndCachesTarget(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let source = ProbeItem.folder("/p/a", 1)
			let target = ProbeItem.folder("/p/b", 1)
			let unrelated = ProbeItem.file("/p/u", 9)
			try cache.seed(parent, source, .folder("/p/third", 1), .file("/p/third/x", 5), unrelated)

			try cache.commitMove(source, target.path, target, parent, cache.changeMark())

			for path in ["/p/a", "/p/third", "/p/third/x"] {
				#expect(cache.containsNothing(path), "\(path)")
			}
			#expect(cache.holds(target))
			#expect(cache.holds(unrelated))
		}

		@Test(arguments: CacheKind.allCases)
		func moveRefusesOlderReadOfOtherItemAtSourcePath(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let source = ProbeItem.file("/p/a", 1)
			try cache.seed(parent, source)
			let mark = try cache.changeMark()

			try cache.commitMove(source, "/p/b", .file("/p/b", 1), parent, mark)

			#expect(try !cache.writeRead(.file("/p/a", 2), parent, mark))
			#expect(cache.containsNothing("/p/a"))
		}

		@Test(arguments: CacheKind.allCases)
		func moveWithoutTargetItemLeavesTargetUncachedAndRefusesOlderRead(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let source = ProbeItem.file("/p/a", 1)
			let displacedItem = ProbeItem.file("/p/b", 2)
			try cache.seed(parent, source, displacedItem)
			let mark = try cache.changeMark()

			try cache.commitMove(source, "/p/b", nil, parent, mark)

			#expect(cache.containsNothing("/p/a"))
			#expect(cache.containsNothing("/p/b"))
			#expect(try !cache.writeRead(displacedItem, parent, mark))
		}

		/// With or without a target item, the commit changes the target path's row only if its parent is still connected.
		@Test(arguments: CacheKind.allCases, [false, true])
		func moveIntoReplacedParentKeepsRowAtTarget(kind: CacheKind, hasTargetItem: Bool) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let source = ProbeItem.file("/p/a", 1)
			let targetParent = ProbeItem.folder("/q", 200)
			let currentItem = ProbeItem.file("/q/b", 8)
			try cache.seed(parent, source, targetParent)
			let mark = try cache.changeMark()
			try cache.seed(.folder("/q", 201), currentItem)

			try cache.commitMove(source, "/q/b", hasTargetItem ? .file("/q/b", 1) : nil, targetParent, mark)

			#expect(cache.containsNothing("/p/a"))
			#expect(cache.holds(currentItem))
		}

		/// The response reports the item elsewhere, so its rows go, and an older read can't bring it back. A replaced parent keeps its row at the path.
		@Test(arguments: CacheKind.allCases, [false, true])
		func mutationOfItemThatLeftRetiresItem(kind: CacheKind, isParentReplaced: Bool) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let item = ProbeItem.file("/p/a", 1)
			let currentItem = ProbeItem.file("/p/a", 8)
			try cache.seed(parent, item, .file("/p/c", 1))
			let mark = try cache.changeMark()
			if isParentReplaced {
				try cache.seed(.folder("/p", 101), currentItem)
			}

			try cache.commitMutationOfItemThatLeft(item, parent)

			#expect(isParentReplaced ? cache.holds(currentItem) : cache.containsNothing("/p/a"))
			#expect(cache.containsNothing("/p/c"))
			#expect(try !cache.writeRead(.file("/p/d", 1), isParentReplaced ? .folder("/p", 101) : parent, mark))
			if !isParentReplaced {
				#expect(try !cache.writeRead(.file("/p/a", 9), parent, mark))
			}
		}

		/// The commit's parent can return to its path, and a read that began before the commit must not cache the path then.
		@Test(arguments: CacheKind.allCases)
		func mutationBelowDisplacedParentRefusesOlderReadOnceParentReturns(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			try cache.seed(parent)
			let mark = try cache.changeMark()
			try cache.seed(.file("/p", 101))

			try cache.commitMutation(.file("/p/a", 3), parent, mark)
			try cache.seed(parent)

			#expect(try !cache.writeRead(.file("/p/a", 2), parent, mark))
			#expect(cache.containsNothing("/p/a"))
		}

		@Test(arguments: CacheKind.allCases)
		func moveBelowDisplacedParentRefusesOlderReadOnceParentReturns(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let source = ProbeItem.file("/a", 1)
			try cache.seed(parent, source)
			let mark = try cache.changeMark()
			try cache.seed(.file("/p", 101))

			try cache.commitMove(source, "/p/b", .file("/p/b", 1), parent, mark)
			try cache.seed(parent)

			#expect(try !cache.writeRead(.file("/p/b", 2), parent, mark))
			#expect(cache.containsNothing("/p/b"))
		}

		/// A read can cache another item at the source while the move is on its way, and identity eviction doesn't reach that row.
		@Test(arguments: CacheKind.allCases)
		func moveRemovesOtherItemAtSourcePath(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let source = ProbeItem.file("/p/a", 1)
			try cache.seed(parent, source)
			let mark = try cache.changeMark()
			#expect(try cache.writeRead(.file("/p/a", 2), parent, mark))

			try cache.commitMove(source, "/p/b", .file("/p/b", 1), parent, mark)

			#expect(cache.containsNothing("/p/a"))
		}

		/// A read marked after the first commit can return the item that the commit cached, which the second commit replaced on the server. The second commit caches nothing, because the path changed since its mark, but it still records the path, so that read is refused too.
		@Test(arguments: CacheKind.allCases)
		func refusedMutationRefusesReadMarkedBeforeIt(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			try cache.seed(parent)
			let oldMark = try cache.changeMark()
			try cache.commitMutation(.file("/p/a", 2), parent, oldMark)
			let readMark = try cache.changeMark()

			try cache.commitMutation(.file("/p/a", 3), parent, oldMark)

			#expect(try !cache.writeRead(.file("/p/a", 2), parent, readMark))
		}

		/// Both items' rows go even if the target item isn't cached, because its path changed since the mark.
		@Test(arguments: CacheKind.allCases, [false, true])
		func moveToItemOfOtherIdentityRetiresBothItems(kind: CacheKind, targetPathChanged: Bool) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let source = ProbeItem.file("/p/a", 1)
			let target = ProbeItem.file("/p/b", 2)
			try cache.seed(parent, source, .file("/p/e", 1), .file("/p/c", 2))
			let mark = try cache.changeMark()
			if targetPathChanged {
				try cache.commitMutation(.file("/p/b", 3), parent, cache.changeMark())
			}

			try cache.commitMove(source, target.path, target, parent, mark)

			for path in ["/p/a", "/p/e", "/p/c"] {
				#expect(cache.containsNothing(path), "\(path)")
			}
			#expect(targetPathChanged ? cache.containsNothing(target.path) : cache.holds(target))
			#expect(try !cache.writeRead(.file("/p/d", 2), parent, mark))
			#expect(try !cache.writeRead(.file("/p/f", 1), parent, mark))
		}

		/// SQLite compares identifiers by bytes, so a target whose identifier Swift equates with the source's is still another identity, whose rows go too.
		@Test
		func moveToCanonicallyEquivalentIdentifierRetiresBothItems() throws {
			let cache = try IdentifierCache<BoxItem>()
			let source = BoxItem(cloudPath: CloudPath("/a"), identifier: "\u{E9}", itemType: .file)
			let target = BoxItem(cloudPath: CloudPath("/b"), identifier: "e\u{301}", itemType: .file)
			try #require(source.changeIdentity == target.changeIdentity)
			try cache.addOrUpdate(source)
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/alias"), identifier: "e\u{301}", itemType: .file))

			try cache.commitMove(of: source, to: target.cloudPath, as: target, ifStillBelow: BoxItem.rootItem, unchangedSince: cache.changeMark())

			#expect(cache.get(CloudPath("/alias")) == nil)
			#expect(cache.get(target.cloudPath) == target)
		}

		@Test(arguments: CacheKind.allCases)
		func invalidateEvictsItemAtEveryPath(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let first = ProbeItem.folder("/p/a", 1)
			let unrelated = ProbeItem.file("/p/u", 9)
			try cache.seed(IdentifierCacheTests.parent, first, .folder("/p/b", 1), .file("/p/b/x", 5), unrelated)

			try cache.invalidateItem(first)

			for path in ["/p/a", "/p/b", "/p/b/x"] {
				#expect(cache.containsNothing(path), "\(path)")
			}
			#expect(cache.holds(unrelated))
		}

		/// Box and pCloud number the root folder like any other, so a row can share its identity.
		@Test(arguments: [CacheKind.box, .pCloud])
		func evictionKeepsRootRow(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let parent = IdentifierCacheTests.parent
			let rootAlias = ProbeItem.folder("/alias", 0)
			try cache.seed(parent, rootAlias)

			try cache.invalidateItem(rootAlias)
			#expect(cache.containsRootItem())

			try cache.seed(rootAlias)
			try cache.commitMove(rootAlias, "/p/b", .folder("/p/b", 0), parent, cache.changeMark())
			#expect(cache.containsRootItem())
		}

		@Test(arguments: [CacheKind.box, .pCloud])
		func fileAndFolderOfOneNumberDontEvictEachOther(kind: CacheKind) throws {
			let cache = try kind.makeProbe()
			let file = ProbeItem.file("/file", 7)
			let folder = ProbeItem.folder("/folder", 7)
			try cache.seed(file, folder)

			try cache.invalidateItem(file)

			#expect(cache.containsNothing(file.path))
			#expect(cache.holds(folder))
		}

		/// A delete acts on the shortcut itself, so it changes nothing about the shortcut's target.
		@Test
		func changeOfShortcutRefusesNoReadOfItsTarget() throws {
			let cache = try IdentifierCache<GoogleDriveItem>()
			let shortcut = GoogleDriveItem(cloudPath: CloudPath("/link"), identifier: "S", itemType: .symlink, shortcut: GoogleDriveShortcut(targetIdentifier: "T", targetItemType: .file))
			let target = GoogleDriveItem(cloudPath: CloudPath("/target"), identifier: "T", itemType: .file, shortcut: nil)
			try cache.addOrUpdate(shortcut)
			let mark = try cache.changeMark()

			try cache.invalidate(shortcut)

			#expect(try cache.addOrUpdate(target, ifStillBelow: GoogleDriveItem.rootItem, unchangedSince: mark).didSave)
		}

		/// Graph can spell one OneDrive Personal drive in several ways, so a change must not be missed because a late response spells it differently.
		@Test
		func changeOfGraphItemRefusesReadWithOtherDriveSpelling() throws {
			let cache = try IdentifierCache<MicrosoftGraphItem>()
			let item = MicrosoftGraphItem(cloudPath: CloudPath("/a"), identifier: "F", driveIdentifier: "0123456789abcdef", itemType: .file, isRemoteItem: false)
			let lateItem = MicrosoftGraphItem(cloudPath: CloudPath("/b"), identifier: "F", driveIdentifier: "0123456789ABCDEF", itemType: .file, isRemoteItem: false)
			try cache.addOrUpdate(item)
			let mark = try cache.changeMark()

			try cache.invalidate(item)

			#expect(try !cache.addOrUpdate(lateItem, ifStillBelow: MicrosoftGraphItem.rootItem, unchangedSince: mark).didSave)
		}

		@Test
		func resolvePathLooksUpAgainIfItsPathChanged() async throws {
			let cache = try IdentifierCache<BoxItem>()
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder))
			var lookupCount = 0

			let item = try await cache.resolvePath(forItemAt: CloudPath("/foo/bar")) { name, parentItem in
				lookupCount += 1
				if lookupCount == 1 {
					try cache.invalidate(BoxItem(cloudPath: CloudPath("/foo/bar"), identifier: "OLD", itemType: .file))
				}
				return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: "B\(lookupCount)", itemType: .file)
			}

			#expect(lookupCount == 2)
			#expect(item.identifier == "B2")
			#expect(cache.get(item.cloudPath) == item)
		}

		@Test
		func resolvePathThrowsIfItsPathChangesDuringBothAttempts() async throws {
			let cache = try IdentifierCache<BoxItem>()
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/foo"), identifier: "F", itemType: .folder))
			var lookupCount = 0

			await #expect(throws: BoxError.inconsistentCache) {
				try await cache.resolvePath(forItemAt: CloudPath("/foo/bar")) { name, parentItem in
					lookupCount += 1
					try cache.invalidate(BoxItem(cloudPath: CloudPath("/foo/bar"), identifier: "OLD", itemType: .file))
					return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: name, itemType: .file)
				}
			}
			#expect(lookupCount == 2)
			#expect(cache.get(CloudPath("/foo/bar")) == nil)
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
