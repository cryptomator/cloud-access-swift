//
//  DirectoryContentCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 11.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import GRDB
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DirectoryContentCacheTests: XCTestCase {
	var cache: DirectoryContentDBCache!
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

	override func setUpWithError() throws {
		let inMemoryDB = try DatabaseQueue()
		cache = try DirectoryContentDBCache(dbWriter: inMemoryDB, maxPageSize: maxPageSize)
	}

	func testDatabaseFileNeedsNoDurability() throws {
		let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directoryURL) }
		let fileCache = try DirectoryContentDBCache(fileAt: directoryURL.appendingPathComponent("db.sqlite"), maxPageSize: maxPageSize)

		try fileCache.dbWriter.read { db in
			XCTAssertEqual("wal", try String.fetchOne(db, sql: "PRAGMA journal_mode"))
			XCTAssertEqual(0, try Int.fetchOne(db, sql: "PRAGMA synchronous"))
			XCTAssertEqual(-500, try Int.fetchOne(db, sql: "PRAGMA cache_size"))
		}
	}

	func testCacheAndRetrieveElement() throws {
		let cloudItemMetadata = CloudItemMetadata(name: "test.txt", cloudPath: CloudPath("/test.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175)
		try assertRoundTrip(of: cloudItemMetadata)
	}

	func testCacheAndRetrieveElementWithoutDate() throws {
		let cloudItemMetadata = CloudItemMetadata(name: "test.txt", cloudPath: CloudPath("/test.txt"), itemType: .file, lastModifiedDate: nil, size: 54175)
		try assertRoundTrip(of: cloudItemMetadata)
	}

	func testCacheAndRetrieveFolder() throws {
		let cloudItemMetadata = CloudItemMetadata(name: "test", cloudPath: CloudPath("/test"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: nil)
		try assertRoundTrip(of: cloudItemMetadata)
	}

	func testCacheAndRetrieveElementWithoutDateAndSize() throws {
		let cloudItemMetadata = CloudItemMetadata(name: "test.txt", cloudPath: CloudPath("/test.txt"), itemType: .file, lastModifiedDate: nil, size: nil)
		try assertRoundTrip(of: cloudItemMetadata)
	}

	func testPagination() throws {
		let rootSnapshot = try fillSnapshot(of: .root, with: rootItems)
		let subfolderSnapshot = try fillSnapshot(of: subfolderPath, with: subFolderItems)

		let initialRootPage = try cache.publish(rootSnapshot)
		XCTAssertEqual("\(rootSnapshot.id.uuidString):2", initialRootPage.nextPageToken)
		XCTAssertEqual(Array(rootItems.prefix(2)), initialRootPage.items)

		let finalRootPage = try cache.getPage(for: .root, pageToken: XCTUnwrap(initialRootPage.nextPageToken))
		XCTAssertNil(finalRootPage.nextPageToken)
		XCTAssertEqual(Array(rootItems.suffix(1)), finalRootPage.items)

		let subfolderPage = try cache.publish(subfolderSnapshot)
		XCTAssertNil(subfolderPage.nextPageToken)
		XCTAssertEqual(subFolderItems, subfolderPage.items)
	}

	func testNonpositivePageSizePagesOneItemAtATime() throws {
		for pageSize in [0, -1] {
			cache = try DirectoryContentDBCache(dbWriter: DatabaseQueue(), maxPageSize: pageSize)
			var pages = try [cache.publish(fillSnapshot(of: .root, with: rootItems))]
			while let pageToken = pages.last?.nextPageToken {
				try pages.append(cache.getPage(for: .root, pageToken: pageToken))
			}
			XCTAssertEqual(rootItems.map { [$0] }, pages.map(\.items))
		}
	}

	func testPublishSinglePageSnapshotLeavesNoRows() throws {
		let snapshot = try fillSnapshot(of: subfolderPath, with: subFolderItems)
		let firstPage = try cache.publish(snapshot)
		XCTAssertNil(firstPage.nextPageToken)
		XCTAssertEqual(subFolderItems, firstPage.items)
		try assertDirectoryContentCacheIsEmpty(cache)
	}

	func testPublishEmptySnapshotLeavesNoRows() throws {
		let firstPage = try cache.publish(DirectoryContentSnapshot(folderEnumerationPath: .root))
		XCTAssertNil(firstPage.nextPageToken)
		XCTAssertTrue(firstPage.items.isEmpty)
		try assertDirectoryContentCacheIsEmpty(cache)
	}

	func testInterleavedSnapshotsOfOneFolder() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: .root)
		let otherSnapshot = DirectoryContentSnapshot(folderEnumerationPath: .root)
		for (index, (item, otherItem)) in zip(rootItems, otherRootItems).enumerated() {
			try cache.save(item, in: snapshot, index: Int64(index + 1))
			try cache.save(otherItem, in: otherSnapshot, index: Int64(index + 1))
		}

		let firstPage = try cache.publish(snapshot)
		let otherFirstPage = try cache.publish(otherSnapshot)
		let secondPage = try cache.getPage(for: .root, pageToken: XCTUnwrap(firstPage.nextPageToken))
		let otherSecondPage = try cache.getPage(for: .root, pageToken: XCTUnwrap(otherFirstPage.nextPageToken))

		XCTAssertEqual(rootItems, firstPage.items + secondPage.items)
		XCTAssertNil(secondPage.nextPageToken)
		XCTAssertEqual(otherRootItems, otherFirstPage.items + otherSecondPage.items)
		XCTAssertNil(otherSecondPage.nextPageToken)
	}

	func testReplayPages() throws {
		let items = rootItems + otherRootItems.prefix(2)
		let firstPage = try cache.publish(fillSnapshot(of: .root, with: items))
		let intermediatePageToken = try XCTUnwrap(firstPage.nextPageToken)
		let intermediatePage = try cache.getPage(for: .root, pageToken: intermediatePageToken)
		let lastPageToken = try XCTUnwrap(intermediatePage.nextPageToken)
		let lastPage = try cache.getPage(for: .root, pageToken: lastPageToken)
		XCTAssertNil(lastPage.nextPageToken)

		let replayedIntermediatePage = try cache.getPage(for: .root, pageToken: intermediatePageToken)
		let replayedLastPage = try cache.getPage(for: .root, pageToken: lastPageToken)
		XCTAssertEqual(intermediatePage.items, replayedIntermediatePage.items)
		XCTAssertEqual(intermediatePage.nextPageToken, replayedIntermediatePage.nextPageToken)
		XCTAssertEqual(lastPage.items, replayedLastPage.items)
		XCTAssertNil(replayedLastPage.nextPageToken)
	}

	func testFifthMultiPagePublicationOfFolderPrunesOldestSnapshot() throws {
		let oldestPageToken = try XCTUnwrap(cache.publish(fillSnapshot(of: .root, with: rootItems)).nextPageToken)
		var newerPageTokens = [String]()
		for _ in 0 ..< DirectoryContentDBCache.retainedSnapshotsPerFolder {
			try newerPageTokens.append(XCTUnwrap(cache.publish(fillSnapshot(of: .root, with: rootItems)).nextPageToken))
		}

		XCTAssertThrowsError(try cache.getPage(for: .root, pageToken: oldestPageToken)) { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}
		for pageToken in newerPageTokens {
			XCTAssertEqual(Array(rootItems.suffix(1)), try cache.getPage(for: .root, pageToken: pageToken).items)
		}
		try assertRowCounts(of: cache, entries: DirectoryContentDBCache.retainedSnapshotsPerFolder * rootItems.count, snapshots: DirectoryContentDBCache.retainedSnapshotsPerFolder)
	}

	func testPublicationsOfOtherFoldersDontPruneSnapshot() throws {
		let pageToken = try XCTUnwrap(cache.publish(fillSnapshot(of: .root, with: rootItems)).nextPageToken)
		for _ in 0 ... DirectoryContentDBCache.retainedSnapshotsPerFolder {
			_ = try cache.publish(fillSnapshot(of: subfolderPath, with: rootItems))
		}

		XCTAssertEqual(Array(rootItems.suffix(1)), try cache.getPage(for: .root, pageToken: pageToken).items)
	}

	func testSinglePagePublicationsDontPruneSnapshot() throws {
		let pageToken = try XCTUnwrap(cache.publish(fillSnapshot(of: .root, with: rootItems)).nextPageToken)
		for _ in 1 ..< DirectoryContentDBCache.retainedSnapshotsPerFolder {
			_ = try cache.publish(fillSnapshot(of: .root, with: rootItems))
		}
		_ = try cache.publish(fillSnapshot(of: .root, with: Array(rootItems.prefix(1))))

		XCTAssertEqual(Array(rootItems.suffix(1)), try cache.getPage(for: .root, pageToken: pageToken).items)
	}

	func testDiscardUnpublishedSnapshot() throws {
		let snapshot = try fillSnapshot(of: .root, with: rootItems)
		XCTAssertThrowsError(try cache.getPage(for: .root, pageToken: "\(snapshot.id.uuidString):2")) { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}

		try cache.discard(snapshot)
		try assertDirectoryContentCacheIsEmpty(cache)
	}

	func testInvalidPageToken() throws {
		let snapshot = try fillSnapshot(of: .root, with: rootItems)
		let snapshotID = snapshot.id.uuidString
		_ = try cache.publish(snapshot)
		let invalidPageTokens = ["2:4", "0:500", "Foo:Bar", "\(UUID().uuidString):1", "\(snapshotID):0", "\(snapshotID):-1", "\(snapshotID):3", "\(snapshotID):4", "\(snapshotID):2:4", "\(snapshotID):", snapshotID]
		for pageToken in invalidPageTokens {
			XCTAssertThrowsError(try cache.getPage(for: .root, pageToken: pageToken), pageToken) { error in
				XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError, pageToken)
			}
		}
		XCTAssertThrowsError(try cache.getPage(for: subfolderPath, pageToken: "\(snapshotID):2")) { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}
	}

	private func fillSnapshot(of folderPath: CloudPath, with items: [CloudItemMetadata]) throws -> DirectoryContentSnapshot {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: folderPath)
		for (index, item) in items.enumerated() {
			try cache.save(item, in: snapshot, index: Int64(index + 1))
		}
		return snapshot
	}

	private func assertRoundTrip(of cloudItemMetadata: CloudItemMetadata, file: StaticString = #filePath, line: UInt = #line) throws {
		let firstPage = try cache.publish(fillSnapshot(of: .root, with: [cloudItemMetadata]))
		XCTAssertNil(firstPage.nextPageToken, file: file, line: line)
		XCTAssertEqual(1, firstPage.items.count, file: file, line: line)
		let cachedElement = try XCTUnwrap(firstPage.items.first, file: file, line: line)
		XCTAssertEqual(cloudItemMetadata, cachedElement, file: file, line: line)
		XCTAssertEqual(cloudItemMetadata.lastModifiedDate, cachedElement.lastModifiedDate, file: file, line: line)
	}
}

extension XCTestCase {
	func assertDirectoryContentCacheIsEmpty(_ cache: DirectoryContentCache, file: StaticString = #filePath, line: UInt = #line) throws {
		try assertRowCounts(of: cache, entries: 0, snapshots: 0, file: file, line: line)
	}

	func assertRowCounts(of cache: DirectoryContentCache, entries: Int, snapshots: Int, file: StaticString = #filePath, line: UInt = #line) throws {
		let cache = try XCTUnwrap(cache as? DirectoryContentDBCache, file: file, line: line)
		XCTAssertEqual(entries, try rowCount(of: "entries", in: cache), file: file, line: line)
		XCTAssertEqual(snapshots, try rowCount(of: "snapshots", in: cache), file: file, line: line)
	}

	private func rowCount(of table: String, in cache: DirectoryContentDBCache) throws -> Int {
		return try cache.dbWriter.read { db in
			try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
		}
	}
}
