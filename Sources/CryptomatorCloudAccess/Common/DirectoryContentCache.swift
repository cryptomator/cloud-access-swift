//
//  DirectoryContentCache.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 08.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

/**
 The contents of a folder that one listing reads, which the cache keeps apart from the contents that other listings of the same folder read.

 Nothing exists in the cache for a snapshot until its first element is saved. No page token resolves to it until it is published.
 */
struct DirectoryContentSnapshot: Sendable {
	let id = UUID()
	let folderEnumerationPath: CloudPath
}

protocol DirectoryContentCache: Sendable {
	/**
	 - Parameter index: The element's position in the snapshot. Positions start at 1 and must have no gaps, because pages are cut by position and end at the snapshot's element count.
	 */
	func save(_ element: CloudItemMetadata, in snapshot: DirectoryContentSnapshot, index: Int64) throws

	func discard(_ snapshot: DirectoryContentSnapshot) throws

	/**
	 Makes page tokens resolve to the snapshot and returns its first page.
	 */
	func publish(_ snapshot: DirectoryContentSnapshot) throws -> CloudItemList

	/**
	 Returns the page of the published snapshot that the page token names.

	 The items of a page are sorted by name.
	 In addition, the number of items in a page never exceeds the initially specified `maxPageSize`.
	 Thus it is possible to perform a paginated  folder content listing (with the cached elements).
	 This is useful, for example, to perform folder listing for folders that have a lot of child items without using a lot of RAM.
	 Reading a page doesn't change the cache, so the same page token returns the same page until later publications of the folder prune its snapshot.
	 - Parameter pageToken: A token of the form `snapshotID:offset`, where `offset` is the number of the snapshot's elements on earlier pages.
	 - Throws: `CloudProviderError.pageTokenInvalid` if the page token is malformed, names no published snapshot of `folderPath`, or names an offset at or past the snapshot's last element.
	 */
	func getPage(for folderPath: CloudPath, pageToken: String) throws -> CloudItemList
}

extension DirectoryContentCache {
	/**
	 Fills a new snapshot of the folder, publishes it and returns its first page. If filling or publishing throws, or if the task is cancelled before the snapshot is published, the snapshot is discarded instead.
	 */
	func publishSnapshot(of folderEnumerationPath: CloudPath, fill: (DirectoryContentSnapshot) async throws -> Void) async throws -> CloudItemList {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: folderEnumerationPath)
		do {
			try await fill(snapshot)
			try Task.checkCancellation()
			return try publish(snapshot)
		} catch {
			try? discard(snapshot)
			throw error
		}
	}
}

struct DirectoryContentDBCache: DirectoryContentCache {
	let dbWriter: any DatabaseWriter
	let maxPageSize: Int

	/// How many published snapshots of a folder that didn't fit on their first page stay readable. A snapshot that fits on its first page is deleted when it is published.
	static let retainedSnapshotsPerFolder = 4

	private static let insertSQL = "INSERT INTO entries (snapshotID, cacheIndex, name, itemType, lastModified, size, folderEnumerationPath) VALUES (?, ?, ?, ?, ?, ?, ?)"

	private static var migrator: DatabaseMigrator {
		var migrator = DatabaseMigrator()
		// Each provider instance creates its own database and deletes it with the instance, so a database never meets a changed schema.
		migrator.registerMigration("initial") { db in
			try db.create(table: "snapshots", body: { table in
				table.column("sequence", .integer).primaryKey(autoincrement: true)
				table.column("id", .text).notNull().unique()
				table.column("folderEnumerationPath", .text).notNull()
			})
			try db.create(table: "entries", body: { table in
				table.column("id", .integer).primaryKey(autoincrement: true)
				table.column("snapshotID", .text).notNull()
				table.column("cacheIndex", .integer).notNull()
				table.column("name", .text).notNull()
				table.column("folderEnumerationPath", .text).notNull()
				table.column("itemType", .text).notNull()
				table.column("lastModified", .double)
				table.column("size", .integer)
				table.uniqueKey(["snapshotID", "cacheIndex"])
			})
		}
		return migrator
	}

	init(dbWriter: any DatabaseWriter, maxPageSize: Int) throws {
		self.dbWriter = dbWriter
		self.maxPageSize = maxPageSize
		try DirectoryContentDBCache.migrator.migrate(dbWriter)
		// reduce the cache size from 2000 KiB to 500 KiB
		try dbWriter.write { db in
			try db.execute(sql: "pragma cache_size = -500")
		}
	}

	func save(_ element: CloudItemMetadata, in snapshot: DirectoryContentSnapshot, index: Int64) throws {
		try autoreleasepool {
			_ = try dbWriter.write { db in
				let statement = try db.cachedStatement(sql: DirectoryContentDBCache.insertSQL)
				try statement.execute(arguments: [snapshot.id.uuidString, index, element.name, element.itemType, element.lastModifiedDate?.timeIntervalSinceReferenceDate, element.size, snapshot.folderEnumerationPath])
			}
		}
	}

	func discard(_ snapshot: DirectoryContentSnapshot) throws {
		try dbWriter.write { db in
			try DirectoryContentDBCache.deleteSnapshot(withID: snapshot.id.uuidString, db)
		}
	}

	/// Inserts the snapshot, reads its first page and deletes or prunes in one transaction, so that a concurrent publication can't prune the snapshot before its first page is read.
	func publish(_ snapshot: DirectoryContentSnapshot) throws -> CloudItemList {
		let snapshotID = snapshot.id.uuidString
		return try dbWriter.write { db in
			try db.execute(sql: "INSERT INTO snapshots (id, folderEnumerationPath) VALUES (?, ?)", arguments: [snapshotID, snapshot.folderEnumerationPath])
			let firstPage = try page(ofSnapshotWithID: snapshotID, offset: 0, db)
			if firstPage.nextPageToken == nil {
				try DirectoryContentDBCache.deleteSnapshot(withID: snapshotID, db)
			} else {
				try DirectoryContentDBCache.pruneSnapshots(of: snapshot.folderEnumerationPath, db)
			}
			return firstPage
		}
	}

	func getPage(for folderPath: CloudPath, pageToken: String) throws -> CloudItemList {
		let components = pageToken.split(separator: ":", omittingEmptySubsequences: false)
		guard components.count == 2, let id = UUID(uuidString: String(components[0])), let offset = Int(components[1]), offset > 0 else {
			throw CloudProviderError.pageTokenInvalid
		}
		let snapshotID = id.uuidString
		return try dbWriter.read { db in
			let isPublished = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM snapshots WHERE id = ? AND folderEnumerationPath = ?", arguments: [snapshotID, folderPath]) == 1
			guard isPublished else {
				throw CloudProviderError.pageTokenInvalid
			}
			return try page(ofSnapshotWithID: snapshotID, offset: offset, db)
		}
	}

	/// - Throws: `CloudProviderError.pageTokenInvalid` if the snapshot has no element after a nonzero offset.
	private func page(ofSnapshotWithID snapshotID: String, offset: Int, _ db: Database) throws -> CloudItemList {
		let count = try CacheElement.filter(CacheElement.Columns.snapshotID == snapshotID).fetchCount(db)
		if offset > 0, offset >= count {
			throw CloudProviderError.pageTokenInvalid
		}
		// `maxPageSize` is `.max` for an unpaged listing, so the end of the page is clamped to avoid an overflow.
		let pageEnd = offset + min(maxPageSize, Int.max - offset)
		let elements = try CacheElement
			.filter(CacheElement.Columns.snapshotID == snapshotID && CacheElement.Columns.cacheIndex > offset && CacheElement.Columns.cacheIndex <= pageEnd)
			.order(CacheElement.Columns.name, CacheElement.Columns.cacheIndex)
			.fetchAll(db)
		let nextPageToken = maxPageSize < count - offset ? "\(snapshotID):\(offset + maxPageSize)" : nil
		return CloudItemList(items: elements.map { CloudItemMetadata(cachedElement: $0) }, nextPageToken: nextPageToken)
	}

	private static func deleteSnapshot(withID snapshotID: String, _ db: Database) throws {
		try db.execute(sql: "DELETE FROM entries WHERE snapshotID = ?", arguments: [snapshotID])
		try db.execute(sql: "DELETE FROM snapshots WHERE id = ?", arguments: [snapshotID])
	}

	/// Deletes all but the folder's `retainedSnapshotsPerFolder` most recently published snapshots.
	private static func pruneSnapshots(of folderEnumerationPath: CloudPath, _ db: Database) throws {
		let prunedSnapshotIDs = "SELECT id FROM snapshots WHERE folderEnumerationPath = ? ORDER BY sequence DESC LIMIT -1 OFFSET ?"
		let arguments: StatementArguments = [folderEnumerationPath, retainedSnapshotsPerFolder]
		try db.execute(sql: "DELETE FROM entries WHERE snapshotID IN (\(prunedSnapshotIDs))", arguments: arguments)
		try db.execute(sql: "DELETE FROM snapshots WHERE id IN (\(prunedSnapshotIDs))", arguments: arguments)
	}

	fileprivate struct CacheElement: Codable {
		var id: Int64?
		var cacheIndex: Int64
		let name: String
		var cloudPath: CloudPath {
			return folderEnumerationPath.appendingPathComponent(name)
		}

		let itemType: CloudItemType
		let lastModified: TimeInterval?
		var lastModifiedDate: Date? {
			guard let timeInterval = lastModified else {
				return nil
			}
			return Date(timeIntervalSinceReferenceDate: timeInterval)
		}

		let size: Int?
		let folderEnumerationPath: CloudPath
	}
}

extension DirectoryContentDBCache.CacheElement: FetchableRecord, PersistableRecord {
	static let databaseTableName = "entries"
	enum Columns: String, ColumnExpression {
		case id, snapshotID, cacheIndex, name, itemType, lastModified, size, folderEnumerationPath
	}
}

private extension CloudItemMetadata {
	init(cachedElement: DirectoryContentDBCache.CacheElement) {
		self.init(name: cachedElement.name, cloudPath: cachedElement.cloudPath, itemType: cachedElement.itemType, lastModifiedDate: cachedElement.lastModifiedDate, size: cachedElement.size)
	}
}
