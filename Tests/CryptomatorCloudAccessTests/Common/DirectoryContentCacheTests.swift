//
//  DirectoryContentCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 11.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class DirectoryContentCacheTests {
		var cache: DirectoryContentDBCache
		let maxPageSize = 2
		let rootItems: [CloudItemMetadata] = [
			.init(name: "test.txt", cloudPath: .init("/test.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
			.init(name: "test1.txt", cloudPath: .init("/test1.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
			.init(name: "subfolder", cloudPath: .init("/subfolder"), itemType: .folder, lastModifiedDate: nil, size: nil)
		]
		let otherRootItems: [CloudItemMetadata] = [
			.init(name: "a.txt", cloudPath: .init("/a.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
			.init(name: "b.txt", cloudPath: .init("/b.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
			.init(name: "c", cloudPath: .init("/c"), itemType: .folder, lastModifiedDate: nil, size: nil)
		]
		let subFolderItems: [CloudItemMetadata] = [
			.init(name: "test.txt", cloudPath: .init("/subfolder/test.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
			.init(name: "test1.txt", cloudPath: .init("/subfolder/test1.txt"), itemType: .file, lastModifiedDate: nil, size: nil)
		]
		let subfolderPath = CloudPath("/subfolder")

		init() throws {
			let inMemoryDB = try DatabaseQueue()
			self.cache = try DirectoryContentDBCache(dbWriter: inMemoryDB, maxPageSize: maxPageSize)
		}

		@Test
		func databaseFileNeedsNoDurability() throws {
			let directoryURL = try makeTemporaryDirectory()
			defer { removeItemRecordingFailure(at: directoryURL) }
			let fileCache = try DirectoryContentDBCache(fileAt: directoryURL.appending(component: "db.sqlite", directoryHint: .notDirectory), maxPageSize: maxPageSize)

			let (journalMode, synchronous, cacheSize) = try fileCache.dbWriter.read { db in
				try (String.fetchOne(db, sql: "PRAGMA journal_mode"), Int.fetchOne(db, sql: "PRAGMA synchronous"), Int.fetchOne(db, sql: "PRAGMA cache_size"))
			}

			#expect(journalMode == "wal")
			#expect(synchronous == 0)
			#expect(cacheSize == -500)
		}

		@Test
		func cacheAndRetrieveElement() throws {
			let cloudItemMetadata = CloudItemMetadata(name: "test.txt", cloudPath: CloudPath("/test.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175)
			try assertRoundTrip(of: cloudItemMetadata)
		}

		@Test
		func cacheAndRetrieveElementWithoutDate() throws {
			let cloudItemMetadata = CloudItemMetadata(name: "test.txt", cloudPath: CloudPath("/test.txt"), itemType: .file, lastModifiedDate: nil, size: 54175)
			try assertRoundTrip(of: cloudItemMetadata)
		}

		@Test
		func cacheAndRetrieveFolder() throws {
			let cloudItemMetadata = CloudItemMetadata(name: "test", cloudPath: CloudPath("/test"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: nil)
			try assertRoundTrip(of: cloudItemMetadata)
		}

		@Test
		func cacheAndRetrieveElementWithoutDateAndSize() throws {
			let cloudItemMetadata = CloudItemMetadata(name: "test.txt", cloudPath: CloudPath("/test.txt"), itemType: .file, lastModifiedDate: nil, size: nil)
			try assertRoundTrip(of: cloudItemMetadata)
		}

		@Test
		func pagination() throws {
			let rootSnapshot = try fillSnapshot(of: .root, with: rootItems)
			let subfolderSnapshot = try fillSnapshot(of: subfolderPath, with: subFolderItems)

			let initialRootPage = try cache.publish(rootSnapshot)
			#expect(initialRootPage.nextPageToken == "\(rootSnapshot.id.uuidString):2")
			#expect(Array(rootItems.prefix(2)) == initialRootPage.items)

			let finalRootPage = try cache.getPage(for: .root, pageToken: #require(initialRootPage.nextPageToken))
			#expect(finalRootPage.nextPageToken == nil)
			#expect(Array(rootItems.suffix(1)) == finalRootPage.items)

			let subfolderPage = try cache.publish(subfolderSnapshot)
			#expect(subfolderPage.nextPageToken == nil)
			#expect(subFolderItems == subfolderPage.items)
		}

		@Test
		func nonpositivePageSizePagesOneItemAtATime() throws {
			for pageSize in [0, -1] {
				cache = try DirectoryContentDBCache(dbWriter: DatabaseQueue(), maxPageSize: pageSize)
				var pages = try [cache.publish(fillSnapshot(of: .root, with: rootItems))]
				while let pageToken = pages.last?.nextPageToken {
					try pages.append(cache.getPage(for: .root, pageToken: pageToken))
				}
				#expect(rootItems.map { [$0] } == pages.map(\.items))
			}
		}

		@Test
		func publishSinglePageSnapshotLeavesNoRows() throws {
			let snapshot = try fillSnapshot(of: subfolderPath, with: subFolderItems)
			let firstPage = try cache.publish(snapshot)
			#expect(firstPage.nextPageToken == nil)
			#expect(subFolderItems == firstPage.items)
			try assertDirectoryContentCacheIsEmpty(cache)
		}

		@Test
		func publishEmptySnapshotLeavesNoRows() throws {
			let firstPage = try cache.publish(DirectoryContentSnapshot(folderEnumerationPath: .root))
			#expect(firstPage.nextPageToken == nil)
			#expect(firstPage.items.isEmpty)
			try assertDirectoryContentCacheIsEmpty(cache)
		}

		@Test
		func interleavedSnapshotsOfOneFolder() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: .root)
			let otherSnapshot = DirectoryContentSnapshot(folderEnumerationPath: .root)
			for (index, (item, otherItem)) in zip(rootItems, otherRootItems).enumerated() {
				try cache.save(item, in: snapshot, index: Int64(index + 1))
				try cache.save(otherItem, in: otherSnapshot, index: Int64(index + 1))
			}

			let firstPage = try cache.publish(snapshot)
			let otherFirstPage = try cache.publish(otherSnapshot)
			let secondPage = try cache.getPage(for: .root, pageToken: #require(firstPage.nextPageToken))
			let otherSecondPage = try cache.getPage(for: .root, pageToken: #require(otherFirstPage.nextPageToken))

			#expect(rootItems == firstPage.items + secondPage.items)
			#expect(secondPage.nextPageToken == nil)
			#expect(otherRootItems == otherFirstPage.items + otherSecondPage.items)
			#expect(otherSecondPage.nextPageToken == nil)
		}

		@Test
		func replayPages() throws {
			let items = rootItems + otherRootItems.prefix(2)
			let firstPage = try cache.publish(fillSnapshot(of: .root, with: items))
			let intermediatePageToken = try #require(firstPage.nextPageToken)
			let intermediatePage = try cache.getPage(for: .root, pageToken: intermediatePageToken)
			let lastPageToken = try #require(intermediatePage.nextPageToken)
			let lastPage = try cache.getPage(for: .root, pageToken: lastPageToken)
			#expect(lastPage.nextPageToken == nil)

			let replayedIntermediatePage = try cache.getPage(for: .root, pageToken: intermediatePageToken)
			let replayedLastPage = try cache.getPage(for: .root, pageToken: lastPageToken)
			#expect(intermediatePage.items == replayedIntermediatePage.items)
			#expect(intermediatePage.nextPageToken == replayedIntermediatePage.nextPageToken)
			#expect(lastPage.items == replayedLastPage.items)
			#expect(replayedLastPage.nextPageToken == nil)
		}

		@Test
		func fifthMultiPagePublicationOfFolderPrunesOldestSnapshot() throws {
			let oldestPageToken = try #require(cache.publish(fillSnapshot(of: .root, with: rootItems)).nextPageToken)
			var newerPageTokens = [String]()
			for _ in 0 ..< DirectoryContentDBCache.retainedSnapshotsPerFolder {
				try newerPageTokens.append(#require(cache.publish(fillSnapshot(of: .root, with: rootItems)).nextPageToken))
			}

			#expect(throws: CloudProviderError.pageTokenInvalid) { try cache.getPage(for: .root, pageToken: oldestPageToken) }
			for pageToken in newerPageTokens {
				#expect(try Array(rootItems.suffix(1)) == cache.getPage(for: .root, pageToken: pageToken).items)
			}
			try assertRowCounts(of: cache, entries: DirectoryContentDBCache.retainedSnapshotsPerFolder * rootItems.count, snapshots: DirectoryContentDBCache.retainedSnapshotsPerFolder)
		}

		@Test
		func publicationsOfOtherFoldersDontPruneSnapshot() throws {
			let pageToken = try #require(cache.publish(fillSnapshot(of: .root, with: rootItems)).nextPageToken)
			for _ in 0 ... DirectoryContentDBCache.retainedSnapshotsPerFolder {
				_ = try cache.publish(fillSnapshot(of: subfolderPath, with: rootItems))
			}

			#expect(try Array(rootItems.suffix(1)) == cache.getPage(for: .root, pageToken: pageToken).items)
		}

		@Test
		func singlePagePublicationsDontPruneSnapshot() throws {
			let pageToken = try #require(cache.publish(fillSnapshot(of: .root, with: rootItems)).nextPageToken)
			for _ in 1 ..< DirectoryContentDBCache.retainedSnapshotsPerFolder {
				_ = try cache.publish(fillSnapshot(of: .root, with: rootItems))
			}
			_ = try cache.publish(fillSnapshot(of: .root, with: Array(rootItems.prefix(1))))

			#expect(try Array(rootItems.suffix(1)) == cache.getPage(for: .root, pageToken: pageToken).items)
		}

		@Test
		func discardUnpublishedSnapshot() throws {
			let snapshot = try fillSnapshot(of: .root, with: rootItems)
			#expect(throws: CloudProviderError.pageTokenInvalid) { try cache.getPage(for: .root, pageToken: "\(snapshot.id.uuidString):2") }

			try cache.discard(snapshot)
			try assertDirectoryContentCacheIsEmpty(cache)
		}

		@Test
		func invalidPageToken() throws {
			let snapshot = try fillSnapshot(of: .root, with: rootItems)
			let snapshotID = snapshot.id.uuidString
			_ = try cache.publish(snapshot)
			let invalidPageTokens = ["2:4", "0:500", "Foo:Bar", "\(UUID().uuidString):1", "\(snapshotID):0", "\(snapshotID):-1", "\(snapshotID):3", "\(snapshotID):4", "\(snapshotID):2:4", "\(snapshotID):", snapshotID]
			for pageToken in invalidPageTokens {
				#expect(throws: CloudProviderError.pageTokenInvalid, "\(pageToken)") { try cache.getPage(for: .root, pageToken: pageToken) }
			}
			#expect(throws: CloudProviderError.pageTokenInvalid) { try cache.getPage(for: subfolderPath, pageToken: "\(snapshotID):2") }
		}

		private func fillSnapshot(of folderPath: CloudPath, with items: [CloudItemMetadata]) throws -> DirectoryContentSnapshot {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: folderPath)
			for (index, item) in items.enumerated() {
				try cache.save(item, in: snapshot, index: Int64(index + 1))
			}
			return snapshot
		}

		private func assertRoundTrip(of cloudItemMetadata: CloudItemMetadata, sourceLocation: SourceLocation = #_sourceLocation) throws {
			let firstPage = try cache.publish(fillSnapshot(of: .root, with: [cloudItemMetadata]))
			#expect(firstPage.nextPageToken == nil, sourceLocation: sourceLocation)
			#expect(firstPage.items.count == 1, sourceLocation: sourceLocation)
			let cachedElement = try #require(firstPage.items.first, sourceLocation: sourceLocation)
			#expect(cloudItemMetadata == cachedElement, sourceLocation: sourceLocation)
		}
	}
}

func assertDirectoryContentCacheIsEmpty(_ cache: DirectoryContentCache, sourceLocation: SourceLocation = #_sourceLocation) throws {
	try assertRowCounts(of: cache, entries: 0, snapshots: 0, sourceLocation: sourceLocation)
}

func assertRowCounts(of cache: DirectoryContentCache, entries: Int, snapshots: Int, sourceLocation: SourceLocation = #_sourceLocation) throws {
	let cache = try #require(cache as? DirectoryContentDBCache, sourceLocation: sourceLocation)
	let entryCount = try rowCount(of: "entries", in: cache)
	let snapshotCount = try rowCount(of: "snapshots", in: cache)
	#expect(entryCount == entries, sourceLocation: sourceLocation)
	#expect(snapshotCount == snapshots, sourceLocation: sourceLocation)
}

func rowCount(of table: String, in cache: DirectoryContentDBCache) throws -> Int {
	return try cache.dbWriter.read { db in
		try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
	}
}
