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
	associatedtype Identifier: DatabaseValueConvertible

	/// The item of the root folder, which a new cache holds.
	static var rootItem: Self { get }
	/// The provider's error for a cache whose rows don't hold together. It is thrown when the cache holds no item of a path's ancestors, not even the root. It is also thrown when both attempts to resolve a path fail. An attempt fails when the write of a looked-up item is refused, because a folder on the path changed or lost its connection to the root, or because a mutation changed the item's path or the item itself. For a delete's or move's source, an attempt also fails when the item and its parent aren't cached and connected once it is resolved. A move also throws it when its target folder left its path while the source was resolved, or has the source folder's path but is another item.
	static var inconsistentCacheError: Error { get }
	var cloudPath: CloudPath { get }
	var identifier: Identifier { get }
	var itemType: CloudItemType { get }
	/// The type of what a request through the item reaches, e.g., a shortcut's target. It decides whether the item can hold items and whether it is listed, downloaded, deleted, moved or replaced as a file or as a folder. It defaults to `itemType`.
	var effectiveItemType: CloudItemType { get }
	/// Names the item that a delete, a move or an upload reported elsewhere acts on, so that the cache can find the item's rows at other paths and refuse a late response about it. Items with the same value count as one item, and they must share their `identifier`, because the cache finds an item's rows by identifier first.
	var changeIdentity: String { get }
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

/// A point in a cache's history of mutations. An operation takes it before it resolves anything, so that the cache can tell whether a mutation changed a path or an item since.
struct ChangeMark: Sendable {
	fileprivate let generation: Int64
}

/**
 Keeps the items of the paths that a provider resolved in a database file of its own, so that a large folder's items don't stay in memory. The cache deletes the file when it is released.

 A response can be processed long after its request was sent. A delete or move trusts the cached row without a request, so a row that a late response wrote could direct it at the wrong item. Each committed mutation therefore records what it changed. A delete or move records its paths and its item, also when its request fails, because the server may have applied it. An upload or folder creation records its path, and also its item if the response reports the item elsewhere. A read's write is refused, and a mutation's commit leaves its path uncached, if the path or the item has a newer record than the `ChangeMark` that the operation took. The records outlive the rows, because invalidation deletes rows. They cover only the mutations of this cache's provider object.
 */
final class IdentifierCache<Item: IdentifierCacheItem>: Sendable {
	/// What a guarded write of a read's response did.
	enum WriteOutcome {
		case refused
		case saved(replacing: Item?)

		var didSave: Bool {
			guard case .saved = self else {
				return false
			}
			return true
		}
	}

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
				table.column(Item.identifierKey, .text).notNull().indexed()
				table.column(Item.itemTypeKey, .text).notNull()
				Item.addExtraColumns(to: table)
			}
			// With `AUTOINCREMENT`, a key that `INSERT OR REPLACE` records again gets a higher generation than any before, even if its old row held the highest.
			try db.create(table: "ChangeRecords") { table in
				table.autoIncrementedPrimaryKey("generation")
				table.column("key", .text).notNull().unique()
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

	/// Returns the mark of the latest change.
	func changeMark() throws -> ChangeMark {
		try dbQueue.read { db in
			try changeMark(in: db)
		}
	}

	/// Caches an item that a read found, unless the parent is no longer the item cached at its path and connected to the root (see `connectedItems(along:in:)`), or a mutation changed the item's path or the item since the mark. A refusal leaves the row at the path as it is.
	@discardableResult
	func addOrUpdate(_ item: Item, ifStillBelow parentItem: Item, unchangedSince mark: ChangeMark) throws -> WriteOutcome {
		try dbQueue.write { db in
			guard try isConnected(parentItem, in: db), try !hasChanged(item, since: mark, in: db) else {
				return .refused
			}
			return try .saved(replacing: save(item, in: db))
		}
	}

	/// Commits an upload or a folder creation. If the parent is no longer connected (see `addOrUpdate(_:ifStillBelow:unchangedSince:)`), the row at the path stays. Otherwise it caches the item. If a mutation changed the item's path or the item since the mark, it leaves the path uncached instead, so that the next operation looks it up.
	func commitMutation(_ item: Item, ifStillBelow parentItem: Item, unchangedSince mark: ChangeMark) throws {
		try dbQueue.write { db in
			let savableItem = try hasChanged(item, since: mark, in: db) ? nil : item
			try commitTarget(savableItem, at: item.cloudPath, ifStillBelow: parentItem, in: db)
		}
	}

	/// Commits an upload whose response reports the item elsewhere than at its path, e.g., a file that another client renamed while its new version was uploaded. It removes every row of the item and leaves the path uncached if the parent is still connected (see `addOrUpdate(_:ifStillBelow:unchangedSince:)`).
	func commitMutation(ofItemThatLeft item: Item, ifStillBelow parentItem: Item) throws {
		try dbQueue.write { db in
			try retire(item, in: db)
			try commitTarget(nil, at: item.cloudPath, ifStillBelow: parentItem, in: db)
		}
	}

	/**
	 Commits a move after a successful response or a failed request. It removes every row of the moved item, the source path's row and the rows below them. If the response reports another item than the source, it removes that item's rows too. It caches the target item under the same conditions as `commitMutation(_:ifStillBelow:unchangedSince:)`.

	 - Parameter targetItem: The moved item at its target, or `nil` if the request failed, which leaves the target path uncached if its parent is still connected.
	 */
	func commitMove(of sourceItem: Item, to targetCloudPath: CloudPath, as targetItem: Item?, ifStillBelow targetParentItem: Item, unchangedSince mark: ChangeMark) throws {
		try dbQueue.write { db in
			// Read before the move's own records, which would refuse its target.
			let savableTargetItem = try targetItem.flatMap { try hasChanged($0, since: mark, in: db) ? nil : $0 }
			try retire(sourceItem, in: db)
			// Compared by bytes, as SQLite compares the keys and identifiers that `retire` reads.
			if let targetItem, !targetItem.changeIdentity.utf8.elementsEqual(sourceItem.changeIdentity.utf8) {
				try retire(targetItem, in: db)
			}
			try deleteSubtree(of: sourceItem.cloudPath, in: db)
			try recordChange(at: sourceItem.cloudPath, in: db)
			try commitTarget(savableTargetItem, at: targetCloudPath, ifStillBelow: targetParentItem, in: db)
		}
	}

	/// Caches the item at the path, or leaves the path uncached if there is no item. If the parent is no longer connected, it keeps the row at the path instead. It records the path either way, because the parent can return to its path, and a response older than this mutation must not be cached there then.
	private func commitTarget(_ savableItem: Item?, at cloudPath: CloudPath, ifStillBelow parentItem: Item, in db: Database) throws {
		if try isConnected(parentItem, in: db) {
			if let savableItem {
				_ = try save(savableItem, in: db)
			} else {
				try deleteSubtree(of: cloudPath, in: db)
			}
		}
		try recordChange(at: cloudPath, in: db)
	}

	/// Returns whether the item is still the item cached at its path and connected to the root (see `connectedItems(along:in:)`).
	func isConnected(_ item: Item) -> Bool {
		let isConnected = try? dbQueue.read { db in
			try self.isConnected(item, in: db)
		}
		return isConnected == true
	}

	private func isConnected(_ item: Item, in db: Database) throws -> Bool {
		return try connectedItem(at: item.cloudPath, in: db)?.isSameItem(as: item) == true
	}

	/// Returns the item of the path together with the item cached at its parent's path, read at once, or `nil` unless both are cached and connected to the root (see `connectedItems(along:in:)`).
	func itemWithParent(at cloudPath: CloudPath) -> (item: Item, parent: Item)? {
		guard let items = try? connectedItems(along: cloudPath), items.count >= 2, items.count == cloudPath.pathComponents.count else {
			return nil
		}
		return (items[items.count - 1], items[items.count - 2])
	}

	/// Returns the items cached along the path, starting at the root and stopping before the first path without a cached item or below an item that is no folder, where no item can have been found, so that each item is cached together with the items of all its ancestors, which are folders. A path that isn't `isResolvable` returns no items.
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

	/// Reads the items like `connectedItems(along:in:)` and, if they don't reach the path, the mark for looking up the rest, in one read.
	private func connectedItemsWithMark(along cloudPath: CloudPath) throws -> (items: [Item], mark: ChangeMark?) {
		try dbQueue.read { db in
			let items = try connectedItems(along: cloudPath, in: db)
			return try (items, items.count < cloudPath.pathComponents.count ? changeMark(in: db) : nil)
		}
	}

	/// Returns the item cached at the path if it is connected to the root (see `connectedItems(along:in:)`).
	private func connectedItem(at cloudPath: CloudPath, in db: Database) throws -> Item? {
		let items = try connectedItems(along: cloudPath, in: db)
		return items.count == cloudPath.pathComponents.count ? items.last : nil
	}

	/// Saves the item and returns the item that was cached at its path before, if any. Unless the same item was cached there, it removes the items below the path, because they weren't cached below this item, e.g., inside a shortcut's target.
	func save(_ item: Item, in db: Database) throws -> Item? {
		let replacedItem = try Item.fetchOne(db, key: item.cloudPath)
		if replacedItem.map({ !$0.isSameItem(as: item) }) ?? true {
			try deleteSubtree(of: item.cloudPath, in: db)
		}
		try item.save(db)
		return replacedItem
	}

	/// Commits a delete, also one whose request failed: removes every row of the item, the row at its path and the rows below them.
	func invalidate(_ item: Item) throws {
		try dbQueue.write { db in
			try retire(item, in: db)
			try deleteSubtree(of: item.cloudPath, in: db)
			try recordChange(at: item.cloudPath, in: db)
		}
	}

	/// Records a change of the item and removes its rows at any path, with the rows below them. It keeps the root's row, because every path resolves from it.
	private func retire(_ item: Item, in db: Database) throws {
		try recordChange(key: Self.recordKey(of: item), in: db)
		// The identifier can be shared by items of another identity, e.g., a pCloud file and folder.
		let rows = try Item.filter(Column(Item.identifierKey) == item.identifier).fetchAll(db)
		for row in rows where row.changeIdentity == item.changeIdentity && row.cloudPath != .root {
			try deleteSubtree(of: row.cloudPath, in: db)
		}
	}

	private func deleteSubtree(of cloudPath: CloudPath, in db: Database) throws {
		try Item.filter(CloudPathSubtree.condition(Column(Item.cloudPathKey), path: cloudPath.path)).deleteAll(db)
	}

	// MARK: - Change Records

	private func changeMark(in db: Database) throws -> ChangeMark {
		let generation = try Int64.fetchOne(db, sql: "SELECT MAX(generation) FROM ChangeRecords")
		return ChangeMark(generation: generation ?? 0)
	}

	/// Whether a mutation changed the item's path or the item since the mark. It checks no ancestor, because every caller also requires the parent to be connected. Replacing or removing a row drops its subtree, so the parent stays connected only while each ancestor's row is the same item.
	private func hasChanged(_ item: Item, since mark: ChangeMark, in db: Database) throws -> Bool {
		let arguments: StatementArguments = [Self.recordKey(of: item.cloudPath), Self.recordKey(of: item), mark.generation]
		return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ChangeRecords WHERE key IN (?, ?) AND generation > ?)", arguments: arguments) ?? false
	}

	private func recordChange(at cloudPath: CloudPath, in db: Database) throws {
		try recordChange(key: Self.recordKey(of: cloudPath), in: db)
	}

	private func recordChange(key: String, in db: Database) throws {
		try db.execute(sql: "INSERT OR REPLACE INTO ChangeRecords (key) VALUES (?)", arguments: [key])
	}

	private static func recordKey(of cloudPath: CloudPath) -> String {
		return "path:\(cloudPath.path)"
	}

	private static func recordKey(of item: Item) -> String {
		return "item:\(item.changeIdentity)"
	}

	// MARK: - Path Resolution

	/**
	 Returns the item of the path, starting at the deepest item cached along it that is connected to the root (see `connectedItems(along:in:)`) and looking up each further component in its parent folder. It caches each item it looked up through `addOrUpdate(_:ifStillBelow:unchangedSince:)`, with a mark taken before the first lookup.

	 If that write is refused, it starts over once from the deepest connected item with a new mark, because a caller uses the returned item without another check. If that happens again, it throws `Item.inconsistentCacheError`.

	 A path that isn't `isResolvable` throws `CloudProviderError.invalidPath` without a lookup.

	 - Parameter lookUpChild: Returns the item of the given name in the given folder, or throws `CloudProviderError.itemNotFound`.
	 */
	func resolvePath(forItemAt cloudPath: CloudPath, lookUpChild: (_ name: String, _ parentItem: Item) async throws -> Item) async throws -> Item {
		try cloudPath.checkResolvable()
		for _ in 0 ..< 2 {
			if let item = try await attemptToResolvePath(forItemAt: cloudPath, lookUpChild: lookUpChild) {
				return item
			}
		}
		throw Item.inconsistentCacheError
	}

	/// Resolves the path like `resolvePath(forItemAt:lookUpChild:)`, or returns `nil` if the write of a looked-up item was refused.
	private func attemptToResolvePath(forItemAt cloudPath: CloudPath, lookUpChild: (_ name: String, _ parentItem: Item) async throws -> Item) async throws -> Item? {
		let (connectedItems, mark) = try connectedItemsWithMark(along: cloudPath)
		guard var item = connectedItems.last else {
			throw Item.inconsistentCacheError
		}
		guard let mark else {
			return item
		}
		for name in cloudPath.pathComponents.dropFirst(connectedItems.count) {
			try Task.checkCancellation()
			let childItem = try await lookUpChild(name, item)
			guard try addOrUpdate(childItem, ifStillBelow: item, unchangedSince: mark).didSave else {
				return nil
			}
			item = childItem
		}
		return item
	}

	/// Returns the item of the path's parent folder, or throws `CloudProviderError.parentFolderDoesNotExist` if a folder on its path doesn't exist. A path that isn't `isResolvable` throws `CloudProviderError.invalidPath`. It is checked before its last component is removed, because the removal standardizes what remains.
	func resolveParentPath(forItemAt cloudPath: CloudPath, lookUpChild: (_ name: String, _ parentItem: Item) async throws -> Item) async throws -> Item {
		try cloudPath.checkResolvable()
		do {
			return try await resolvePath(forItemAt: cloudPath.deletingLastPathComponent(), lookUpChild: lookUpChild)
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}
}
