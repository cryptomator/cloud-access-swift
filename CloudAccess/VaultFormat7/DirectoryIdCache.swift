//
//  DirectoryIdCache.swift
//  CloudAccess
//
//  Created by Sebastian Stenzel on 15.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import Promises

struct CachedEntry: Decodable, FetchableRecord, TableRecord {
	static let databaseTableName = "entries"
	let cleartextPath: URL
	let dirId: Data
}

extension CachedEntry: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container["cleartextPath"] = cleartextPath
		container["dirId"] = dirId
	}
}

internal class DirectoryIdCache {
	private let inMemoryDB: DatabaseQueue

	public init() throws {
		self.inMemoryDB = DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: CachedEntry.databaseTableName) { table in
				table.column("cleartextPath", .text).notNull().primaryKey()
				table.column("dirId", .blob).notNull()
			}
			try CachedEntry(cleartextPath: URL(fileURLWithPath: "/"), dirId: Data([])).save(db)
		}
	}

	public func get(_ cleartextPath: URL, onMiss: @escaping (_ cleartextPath: URL, _ parentDirId: Data) throws -> Promise<Data>) -> Promise<Data> {
		do {
			if let cached = try getCached(cleartextPath) {
				return Promise(cached)
			} else {
				return get(cleartextPath.deletingLastPathComponent(), onMiss: onMiss).then { parentDirId -> Promise<Data> in
					return try onMiss(cleartextPath, parentDirId)
				}.then { dirId -> Data in
					try self.addToCache(cleartextPath, dirId: dirId)
					return dirId
				}
			}
		} catch {
			return Promise(error)
		}
	}

	public func invalidate(_ cleartextPath: URL) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(CachedEntry.databaseTableName) WHERE cleartextPath LIKE ?", arguments: [cleartextPath.absoluteString + "%"])
		}
	}

	internal func addToCache(_ cleartextPath: URL, dirId: Data) throws {
		try inMemoryDB.write { db in
			try CachedEntry(cleartextPath: cleartextPath, dirId: dirId).save(db)
		}
	}

	internal func getCached(_ cleartextPath: URL) throws -> Data? {
		let entry: CachedEntry? = try inMemoryDB.read { db in
			return try CachedEntry.fetchOne(db, key: cleartextPath)
		}
		return entry?.dirId
	}
}
