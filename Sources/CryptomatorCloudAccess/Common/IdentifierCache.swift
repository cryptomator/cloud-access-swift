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
protocol IdentifierCacheItem: FetchableRecord, PersistableRecord {
	/// The item of the root folder, which a new cache holds.
	static var rootItem: Self { get }
	/// The provider's error for a cache that holds no item of a path's ancestors, not even the root.
	static var inconsistentCacheError: Error { get }
	var cloudPath: CloudPath { get }
	/// Adds the columns of the item's properties besides its cloud path, identifier and item type.
	static func addExtraColumns(to table: TableDefinition)
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
}

/// Matches a cloud path and its descendants, comparing the paths literally and case-sensitively, so that no character of a path acts as a wildcard.
enum CloudPathSubtree {
	static func condition(column: String) -> String {
		return "\(column) = ? OR substr(\(column), 1, length(?)) = ?"
	}

	static func arguments(for cloudPath: CloudPath) -> StatementArguments {
		let path = cloudPath.path
		let prefix = path == "/" ? path : path + "/"
		return [path, prefix, prefix]
	}
}

/// Keeps the items of the paths that a provider resolved, in memory.
final class IdentifierCache<Item: IdentifierCacheItem>: Sendable {
	private let inMemoryDB: DatabaseQueue

	init() throws {
		self.inMemoryDB = try DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: Item.databaseTableName) { table in
				table.column(Item.cloudPathKey, .text).notNull().primaryKey()
				table.column(Item.identifierKey, .text).notNull()
				table.column(Item.itemTypeKey, .text).notNull()
				Item.addExtraColumns(to: table)
			}
			try Item.rootItem.save(db)
		}
	}

	func get(_ cloudPath: CloudPath) -> Item? {
		try? inMemoryDB.read { db in
			return try Item.fetchOne(db, key: cloudPath)
		}
	}

	func addOrUpdate(_ item: Item) throws {
		try inMemoryDB.write { db in
			try item.save(db)
		}
	}

	/// Removes the item and the items of its descendants.
	func invalidate(_ item: Item) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(Item.databaseTableName) WHERE \(CloudPathSubtree.condition(column: Item.cloudPathKey))", arguments: CloudPathSubtree.arguments(for: item.cloudPath))
		}
	}

	// MARK: - Path Resolution

	/**
	 Returns the item of the path, starting at its nearest cached ancestor and looking up each further component in its parent folder. Every item that was looked up is cached.

	 - Parameter lookUpChild: Returns the item of the given name in the given folder, or throws `CloudProviderError.itemNotFound`.
	 */
	func resolvePath(forItemAt cloudPath: CloudPath, lookUpChild: (_ name: String, _ parentItem: Item) async throws -> Item) async throws -> Item {
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
			item = try await lookUpChild(name, item)
			try addOrUpdate(item)
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
