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

private struct CachedEntry: Decodable, FetchableRecord, TableRecord {
	static let databaseTableName = "entries"
	static let cleartextURLKey = "cleartextURL"
	static let dirIdKey = "dirId"
	let cleartextURL: URL
	let dirId: Data
}

extension CachedEntry: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container[CachedEntry.cleartextURLKey] = cleartextURL
		container[CachedEntry.dirIdKey] = dirId
	}
}

class DirectoryIdCache {
	private let inMemoryDB: DatabaseQueue

	init() throws {
		self.inMemoryDB = DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: CachedEntry.databaseTableName) { table in
				table.column(CachedEntry.cleartextURLKey, .text).notNull().primaryKey()
				table.column(CachedEntry.dirIdKey, .blob).notNull()
			}
			try CachedEntry(cleartextURL: URL(fileURLWithPath: "/", isDirectory: true), dirId: Data([])).save(db)
		}
	}

	func get(_ cleartextURL: URL, onMiss: @escaping (_ cleartextURL: URL, _ parentDirId: Data) throws -> Promise<Data>) -> Promise<Data> {
		do {
			if let cached = try getCached(cleartextURL) {
				return Promise(cached)
			} else {
				return get(cleartextURL.deletingLastPathComponent(), onMiss: onMiss).then { parentDirId in
					return try onMiss(cleartextURL, parentDirId)
				}.then { dirId -> Data in
					try self.addToCache(cleartextURL, dirId: dirId)
					return dirId
				}
			}
		} catch {
			return Promise(error)
		}
	}

	func invalidate(_ cleartextURL: URL) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(CachedEntry.databaseTableName) WHERE \(CachedEntry.cleartextURLKey) LIKE ?", arguments: ["\(cleartextURL.absoluteString)%"])
		}
	}

	// MARK: - Internal

	func addToCache(_ cleartextURL: URL, dirId: Data) throws {
		try inMemoryDB.write { db in
			try CachedEntry(cleartextURL: cleartextURL, dirId: dirId).save(db)
		}
	}

	func getCached(_ cleartextURL: URL) throws -> Data? {
		let entry: CachedEntry? = try inMemoryDB.read { db in
			return try CachedEntry.fetchOne(db, key: cleartextURL)
		}
		return entry?.dirId
	}
}
