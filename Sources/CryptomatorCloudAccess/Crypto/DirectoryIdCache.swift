//
//  DirectoryIdCache.swift
//  CryptomatorCloudAccess
//
//  Created by Sebastian Stenzel on 15.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import Promises

private struct CachedEntry: Decodable, FetchableRecord, TableRecord {
	static let databaseTableName = "entries"
	static let cleartextPathKey = "cleartextPath"
	static let dirIdKey = "dirId"
	let cleartextPath: String
	let dirId: Data
}

extension CachedEntry: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container[CachedEntry.cleartextPathKey] = cleartextPath
		container[CachedEntry.dirIdKey] = dirId
	}
}

class DirectoryIdCache {
	private let inMemoryDB: DatabaseQueue

	init() throws {
		self.inMemoryDB = DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: CachedEntry.databaseTableName) { table in
				table.column(CachedEntry.cleartextPathKey, .text).notNull().primaryKey()
				table.column(CachedEntry.dirIdKey, .blob).notNull()
			}
			try CachedEntry(cleartextPath: "/", dirId: Data([])).save(db)
		}
	}

	func get(_ cleartextPath: CloudPath, onMiss: @escaping (_ cleartextPath: CloudPath, _ parentDirId: Data) throws -> Promise<Data>) -> Promise<Data> {
		do {
			if let cached = try get(cleartextPath) {
				return Promise(cached)
			} else {
				return get(cleartextPath.deletingLastPathComponent(), onMiss: onMiss).then { parentDirId in
					return try onMiss(cleartextPath, parentDirId)
				}.then { dirId -> Data in
					try self.addOrUpdate(cleartextPath, dirId: dirId)
					return dirId
				}
			}
		} catch {
			return Promise(error)
		}
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

	func invalidate(_ cleartextPath: CloudPath) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(CachedEntry.databaseTableName) WHERE \(CachedEntry.cleartextPathKey) LIKE ?", arguments: ["\(cleartextPath.path)%"])
		}
	}
}
