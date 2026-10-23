//
//  DirectoryIdCache.swift
//  CryptomatorCloudAccess
//
//  Created by Sebastian Stenzel on 15.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

private struct CachedEntry: Decodable, FetchableRecord, TableRecord {
	static let databaseTableName = "entries"
	static let cleartextPathKey = "cleartextPath"
	static let dirIdKey = "dirId"
	let cleartextPath: String
	let dirId: Data
}

extension CachedEntry: PersistableRecord {
	func encode(to container: inout PersistenceContainer) throws {
		container[CachedEntry.cleartextPathKey] = cleartextPath
		container[CachedEntry.dirIdKey] = dirId
	}
}

final class DirectoryIdCache: Sendable {
	private let inMemoryDB: DatabaseQueue

	init() throws {
		self.inMemoryDB = try DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: CachedEntry.databaseTableName) { table in
				table.column(CachedEntry.cleartextPathKey, .text).notNull().primaryKey()
				table.column(CachedEntry.dirIdKey, .blob).notNull()
			}
			try CachedEntry(cleartextPath: "/", dirId: Data([])).save(db)
		}
	}

	func get(_ cleartextPath: CloudPath, onMiss: @Sendable (_ cleartextPath: CloudPath, _ parentDirId: Data) async throws -> Data) async throws -> Data {
		if let cached = try get(cleartextPath) {
			return cached
		}
		let parentDirId = try await get(cleartextPath.deletingLastPathComponent(), onMiss: onMiss)
		let dirId = try await onMiss(cleartextPath, parentDirId)
		try addOrUpdate(cleartextPath, dirId: dirId)
		return dirId
	}

	func get(_ cleartextPath: CloudPath) throws -> Data? {
		let entry: CachedEntry? = try inMemoryDB.read { db in
			return try CachedEntry.fetchOne(db, key: cleartextPath.path)
		}
		return entry?.dirId
	}

	func addOrUpdate(_ cleartextPath: CloudPath, dirId: Data) throws {
		try inMemoryDB.write { db in
			try CachedEntry(cleartextPath: cleartextPath.path, dirId: dirId).save(db)
		}
	}

	/// Removes the directory ID of the path and those of its descendants.
	func invalidate(_ cleartextPath: CloudPath) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(CachedEntry.databaseTableName) WHERE \(CloudPathSubtree.condition(column: CachedEntry.cleartextPathKey))", arguments: CloudPathSubtree.arguments(for: cleartextPath))
		}
	}
}
