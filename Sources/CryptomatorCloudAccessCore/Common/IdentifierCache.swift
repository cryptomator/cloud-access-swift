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
	/// The provider's error for a cache whose rows don't hold together. It is thrown when the cache holds no item of a path's ancestors, not even the root. It is also thrown when a folder on a path changed or lost its connection to the root during both attempts to resolve the path, and when a move's target folder left its path while the source was resolved, or has the source folder's path but is another item.
	static var inconsistentCacheError: Error { get }
	var cloudPath: CloudPath { get }
	var itemType: CloudItemType { get }
	/// The type of what a request through the item reaches, e.g., a shortcut's target. It decides whether the item can hold items and whether it is listed, downloaded, deleted, moved or replaced as a file or as a folder. It defaults to `itemType`.
	var effectiveItemType: CloudItemType { get }
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

	var effectiveItemType: CloudItemType {
		return itemType
	}

	func isSameItem(as other: Self) -> Bool {
		return self == other
	}
}

extension CloudPath {
	/// Whether the path is the root or absolute with every component below the root naming one item, i.e., not empty, `.` or `..`. Only such a path reaches the root by removing its last component and resolves to the item it names. A decoded path keeps its spelling, unlike one built with `init(_:)`.
	var isResolvable: Bool {
		return self == .root || isAbsolute && pathComponents.dropFirst().allSatisfy(\.isSinglePathComponent)
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

	/// Adds or updates the item. Saving it where another item was cached removes the items below the path, because they were cached below the replaced item, e.g. inside a shortcut's target. Saving it where no item was cached removes them too, because only a write without the parent check can have left them there.
	func addOrUpdate(_ item: Item) throws {
		_ = try replace(item)
	}

	/// Adds or updates the item like `addOrUpdate(_:)` and returns the item that was cached at its path before, if any.
	func replace(_ item: Item) throws -> Item? {
		try dbQueue.write { db in
			try save(item, in: db)
		}
	}

	/// Adds or updates the item like `addOrUpdate(_:)` only if the parent is still the item cached at its path and connected to the root (see `connectedItems(along:in:)`), and returns whether it did.
	@discardableResult
	func addOrUpdate(_ item: Item, ifStillBelow parentItem: Item) throws -> Bool {
		try dbQueue.write { db in
			guard try connectedItem(at: parentItem.cloudPath, in: db)?.isSameItem(as: parentItem) == true else {
				return false
			}
			_ = try save(item, in: db)
			return true
		}
	}

	/// Returns whether the item is still the item cached at its path and connected to the root (see `connectedItems(along:in:)`).
	func isConnected(_ item: Item) -> Bool {
		let cachedItem = try? dbQueue.read { db in
			try connectedItem(at: item.cloudPath, in: db)
		}
		return cachedItem?.isSameItem(as: item) == true
	}

	/// Returns the item of the path together with the item cached at its parent's path, read at once, or `nil` unless both are cached and connected to the root (see `connectedItems(along:in:)`). The pair can still be wrong: a write without the parent check, e.g., of a listing that went through a replaced folder row, can cache an item below a folder that it wasn't found in.
	func itemWithParent(at cloudPath: CloudPath) -> (item: Item, parent: Item)? {
		guard let items = try? connectedItems(along: cloudPath), items.count >= 2, items.count == cloudPath.pathComponents.count else {
			return nil
		}
		return (items[items.count - 1], items[items.count - 2])
	}

	/**
	 Returns the items cached along the path, starting at the root and stopping before the first path without a cached item or below an item that is no folder, where no item can have been found, so that each item is cached together with the items of all its ancestors, which are folders.

	 A write without the parent check can cache an item after its folder's item was removed, e.g., a listing that is still running when a move removes the items of the listed folder's ancestor. Such an item, and every item below it, is left out until the first missing item above it is cached again, which removes it with the items below that path. A path that isn't `isResolvable` returns no items.
	 */
	private func connectedItems(along cloudPath: CloudPath, in db: Database) throws -> [Item] {
		guard cloudPath.isResolvable, let rootItem = try Item.fetchOne(db, key: CloudPath.root) else {
			return []
		}
		var items = [rootItem]
		var path = CloudPath.root
		for name in cloudPath.pathComponents.dropFirst() {
			guard items.last?.effectiveItemType == .folder else {
				break
			}
			path = path.appendingPathComponent(name)
			guard let item = try Item.fetchOne(db, key: path) else {
				break
			}
			items.append(item)
		}
		return items
	}

	/// Reads the items like `connectedItems(along:in:)` at once.
	private func connectedItems(along cloudPath: CloudPath) throws -> [Item] {
		try dbQueue.read { db in
			try connectedItems(along: cloudPath, in: db)
		}
	}

	/// Returns the item cached at the path if it is connected to the root (see `connectedItems(along:in:)`).
	private func connectedItem(at cloudPath: CloudPath, in db: Database) throws -> Item? {
		let items = try connectedItems(along: cloudPath, in: db)
		return items.count == cloudPath.pathComponents.count ? items.last : nil
	}

	/// Saves the item. Unless the same item was already cached at its path, it removes the items below the path, including items that a write without the parent check left there while no item was cached at the path.
	private func save(_ item: Item, in db: Database) throws -> Item? {
		let replacedItem = try Item.fetchOne(db, key: item.cloudPath)
		if replacedItem.map({ !$0.isSameItem(as: item) }) ?? true {
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
	 Returns the item of the path, starting at the deepest item cached along it that is connected to the root (see `connectedItems(along:in:)`) and looking up each further component in its parent folder. It caches each item it looked up only if its parent folder's cached item is still the same item it was looked up in and connected to the root.

	 If a parent folder's cached item changed or lost its connection to the root during a lookup, it starts over once from the deepest connected item, because a caller caches the returned item and the items below it without that check. If that happens again, it throws `Item.inconsistentCacheError`.

	 A path that isn't `isResolvable` throws `CloudProviderError.itemNotFound` without a lookup.

	 - Parameter lookUpChild: Returns the item of the given name in the given folder, or throws `CloudProviderError.itemNotFound`.
	 */
	func resolvePath(forItemAt cloudPath: CloudPath, lookUpChild: (_ name: String, _ parentItem: Item) async throws -> Item) async throws -> Item {
		guard cloudPath.isResolvable else {
			throw CloudProviderError.itemNotFound
		}
		for _ in 0 ..< 2 {
			if let item = try await attemptToResolvePath(forItemAt: cloudPath, lookUpChild: lookUpChild) {
				return item
			}
		}
		throw Item.inconsistentCacheError
	}

	/// Resolves the path like `resolvePath(forItemAt:lookUpChild:)`, or returns `nil` if a parent folder's cached item changed or lost its connection to the root during a lookup.
	private func attemptToResolvePath(forItemAt cloudPath: CloudPath, lookUpChild: (_ name: String, _ parentItem: Item) async throws -> Item) async throws -> Item? {
		let connectedItems = try connectedItems(along: cloudPath)
		guard var item = connectedItems.last else {
			throw Item.inconsistentCacheError
		}
		for name in cloudPath.pathComponents.dropFirst(connectedItems.count) {
			try Task.checkCancellation()
			let childItem = try await lookUpChild(name, item)
			guard try addOrUpdate(childItem, ifStillBelow: item) else {
				return nil
			}
			item = childItem
		}
		return item
	}

	/// Returns the item of the path's parent folder, or throws `CloudProviderError.parentFolderDoesNotExist` if a folder on its path doesn't exist. The path itself is checked with `isResolvable`, because removing its last component standardizes what remains.
	func resolveParentPath(forItemAt cloudPath: CloudPath, lookUpChild: (_ name: String, _ parentItem: Item) async throws -> Item) async throws -> Item {
		guard cloudPath.isResolvable else {
			throw CloudProviderError.parentFolderDoesNotExist
		}
		do {
			return try await resolvePath(forItemAt: cloudPath.deletingLastPathComponent(), lookUpChild: lookUpChild)
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}
}
