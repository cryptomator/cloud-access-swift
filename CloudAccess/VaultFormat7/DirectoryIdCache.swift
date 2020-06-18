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
	let cleartextURL: URL
	let dirId: Data
}

extension CachedEntry: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container["cleartextURL"] = cleartextURL
		container["dirId"] = dirId
	}
}

internal class DirectoryIdCache {
	private let inMemoryDB: DatabaseQueue

	public init() throws {
		self.inMemoryDB = DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: CachedEntry.databaseTableName) { table in
				table.column("cleartextURL", .text).notNull().primaryKey()
				table.column("dirId", .blob).notNull()
			}
			try CachedEntry(cleartextURL: URL(fileURLWithPath: "/"), dirId: Data([])).save(db)
		}
	}

	public func get(_ cleartextURL: URL, onMiss: @escaping (_ cleartextURL: URL, _ parentDirId: Data) throws -> Promise<Data>) -> Promise<Data> {
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

	public func invalidate(_ cleartextURL: URL) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(CachedEntry.databaseTableName) WHERE cleartextURL LIKE ?", arguments: ["\(cleartextURL.absoluteString)%"])
		}
	}

	internal func addToCache(_ cleartextURL: URL, dirId: Data) throws {
		try inMemoryDB.write { db in
			try CachedEntry(cleartextURL: cleartextURL, dirId: dirId).save(db)
		}
	}

	internal func getCached(_ cleartextURL: URL) throws -> Data? {
		let entry: CachedEntry? = try inMemoryDB.read { db in
			return try CachedEntry.fetchOne(db, key: cleartextURL)
		}
		return entry?.dirId
	}
}
