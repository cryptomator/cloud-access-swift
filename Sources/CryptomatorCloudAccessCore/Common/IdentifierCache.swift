//
//  IdentifierCache.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 22.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

/// An item of a provider that addresses its items by identifiers, which `IdentifierCache` keeps under its cloud path.
protocol IdentifierCacheItem: FetchableRecord, PersistableRecord, Equatable {
	/// The item of the root folder, which a new cache holds.
	static var rootItem: Self { get }
	/// The provider's error for a cache that holds no item of a path's ancestors, not even the root, or whose item of a folder on a path changed during both attempts to resolve the path.
	static var inconsistentCacheError: Error { get }
	var cloudPath: CloudPath { get }
	/// Adds the columns of the item's properties besides its cloud path, identifier and item type.
	static func addExtraColumns(to table: TableDefinition)
	/// Whether the item is the same as the other, so that the items cached below the other stay valid. It compares only what a request for a descendant goes through, never a value that changes with the item's content.
	func isSameItem(as other: Self) -> Bool
}

extension IdentifierCacheItem {
	static var databaseTableName: String {
		return "CachedEntries"
	}

	static var cloudPathKey: String {
		return "cloudPath"
	}

	static var identifierKey: String {
		return "identifier"
	}

	static var itemTypeKey: String {
		return "itemType"
	}

	static func addExtraColumns(to table: TableDefinition) {}

	func isSameItem(as other: Self) -> Bool {
		return self == other
	}
}

/// Matches a cloud path and its descendants, comparing the paths literally and case-sensitively, so that no character of a path acts as a wildcard.
enum CloudPathSubtree {
	static func condition(_ column: Column, path: String) -> SQLExpression {
		// A descendant starts with `<base>/`, where `base` drops the root's slash. Under the column's default `BINARY` collation in a UTF-8 database, these are exactly the paths from `<base>/` up to, but excluding, `<base>0` (`0` is the byte after `/`). The column's index can search that range.
		let base = path == "/" ? "" : path
		return column == path || (column >= base + "/" && column < base + "0")
	}
}

extension DatabaseQueue {
	/// Opens a database file that is written without durability (`synchronous = OFF`), so its owner must delete the file with itself and never reopen it.
	static func withoutDurability(path: String) throws -> DatabaseQueue {
		var configuration = Configuration()
		// WAL, because a rollback journal is created and deleted for every commit, and a `MEMORY` journal would hold every page that a large transaction changes.
		configuration.journalMode = .wal
		let dbQueue = try DatabaseQueue(path: path, configuration: configuration)
		// Set after opening, because GRDB's WAL setup sets `synchronous = NORMAL`.
		try dbQueue.writeWithoutTransaction { db in
			try db.execute(sql: "PRAGMA synchronous = OFF")
		}
		return dbQueue
	}
}

/// Keeps the items of the paths that a provider resolved in a database file of its own, so that a large folder's items don't stay in memory. The cache deletes the file when it is released.
final class IdentifierCache<Item: IdentifierCacheItem>: Sendable {
	let directoryURL: URL
	let dbQueue: DatabaseQueue

	init() throws {
		self.directoryURL = try ProcessTemporaryDirectory.shared.makeDirectory()
		self.dbQueue = try DatabaseQueue.withoutDurability(path: directoryURL.appendingPathComponent("identifiers.sqlite").path)
		try dbQueue.writeWithoutTransaction { db in
			try db.execute(sql: "PRAGMA cache_size = -500")
		}
		try dbQueue.write { db in
			try db.create(table: Item.databaseTableName) { table in
				table.column(Item.cloudPathKey, .text).notNull().primaryKey()
				table.column(Item.identifierKey, .text).notNull()
				table.column(Item.itemTypeKey, .text).notNull()
				Item.addExtraColumns(to: table)
			}
			try Item.rootItem.save(db)
		}
	}

	deinit {
		try? FileManager.default.removeItem(at: directoryURL)
	}

	func get(_ cloudPath: CloudPath) -> Item? {
		try? dbQueue.read { db in
			return try Item.fetchOne(db, key: cloudPath)
		}
	}

	/// Adds or updates the item. Replacing another item also removes the items of the path's descendants, because they were cached below the replaced item, e.g. inside a shortcut's target.
	func addOrUpdate(_ item: Item) throws {
		_ = try replace(item)
	}

	/// Adds or updates the item like `addOrUpdate(_:)` and returns the item that was cached at its path before, if any.
	func replace(_ item: Item) throws -> Item? {
		try dbQueue.write { db in
			try save(item, in: db)
		}
	}

	/// Adds or updates the item like `addOrUpdate(_:)` only if the cached item at the parent's path is still the same item as the parent, and returns whether it did.
	private func addOrUpdate(_ item: Item, ifStillBelow parentItem: Item) throws -> Bool {
		try dbQueue.write { db in
			guard let cachedParentItem = try Item.fetchOne(db, key: parentItem.cloudPath), cachedParentItem.isSameItem(as: parentItem) else {
				return false
			}
			_ = try save(item, in: db)
			return true
		}
	}

	private func save(_ item: Item, in db: Database) throws -> Item? {
		let replacedItem = try Item.fetchOne(db, key: item.cloudPath)
		if let replacedItem, !replacedItem.isSameItem(as: item) {
			try deleteSubtree(of: item.cloudPath, in: db)
		}
		try item.save(db)
		return replacedItem
	}

	/// Removes the item and the items of its descendants.
	func invalidate(_ item: Item) throws {
		try dbQueue.write { db in
			try deleteSubtree(of: item.cloudPath, in: db)
		}
	}

	private func deleteSubtree(of cloudPath: CloudPath, in db: Database) throws {
		try Item.filter(CloudPathSubtree.condition(Column(Item.cloudPathKey), path: cloudPath.path)).deleteAll(db)
	}

	// MARK: - Path Resolution

	/**
	 Returns the item of the path, starting at the path or its nearest cached ancestor and looking up each further component in its parent folder. It caches each item it looked up only if its parent folder's cached item is still the same item it was looked up in.

	 If a parent folder's cached item changed during a lookup, it starts over once from the nearest cached ancestor, because a caller caches the returned item and the items below it without that check. If that happens again, it throws `Item.inconsistentCacheError`.

	 - Parameter lookUpChild: Returns the item of the given name in the given folder, or throws `CloudProviderError.itemNotFound`.
	 */
	func resolvePath(forItemAt cloudPath: CloudPath, lookUpChild: (_ name: String, _ parentItem: Item) async throws -> Item) async throws -> Item {
		for _ in 0 ..< 2 {
			if let item = try await attemptToResolvePath(forItemAt: cloudPath, lookUpChild: lookUpChild) {
				return item
			}
		}
		throw Item.inconsistentCacheError
	}

	/// Resolves the path like `resolvePath(forItemAt:lookUpChild:)`, or returns `nil` if a parent folder's cached item changed during a lookup.
	private func attemptToResolvePath(forItemAt cloudPath: CloudPath, lookUpChild: (_ name: String, _ parentItem: Item) async throws -> Item) async throws -> Item? {
		var cachedPath = cloudPath
		var cachedItem = get(cachedPath)
		while cachedItem == nil, !cachedPath.pathComponents.isEmpty {
			cachedPath = cachedPath.deletingLastPathComponent()
			cachedItem = get(cachedPath)
		}
		guard var item = cachedItem else {
			throw Item.inconsistentCacheError
		}
		for name in cloudPath.pathComponents.dropFirst(cachedPath.pathComponents.count) {
			try Task.checkCancellation()
			let childItem = try await lookUpChild(name, item)
			guard try addOrUpdate(childItem, ifStillBelow: item) else {
				return nil
			}
			item = childItem
		}
		return item
	}

	/// Returns the item of the path's parent folder, or throws `CloudProviderError.parentFolderDoesNotExist` if a folder on its path doesn't exist.
	func resolveParentPath(forItemAt cloudPath: CloudPath, lookUpChild: (_ name: String, _ parentItem: Item) async throws -> Item) async throws -> Item {
		do {
			return try await resolvePath(forItemAt: cloudPath.deletingLastPathComponent(), lookUpChild: lookUpChild)
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}
}
