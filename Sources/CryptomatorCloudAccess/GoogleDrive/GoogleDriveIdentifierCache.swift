//
//  GoogleDriveIdentifierCache.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 11.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

private struct CachedEntry: Decodable, FetchableRecord, TableRecord {
	static let databaseTableName = "CachedEntries"
	static let itemIdentifierKey = "itemIdentifier"
	static let cloudPathKey = "cloudPath"

	var itemIdentifier: String
	let cloudPath: CloudPath
}

extension CachedEntry: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container[CachedEntry.itemIdentifierKey] = itemIdentifier
		container[CachedEntry.cloudPathKey] = cloudPath
	}
}

class GoogleDriveIdentifierCache {
	private let inMemoryDB: DatabaseQueue

	init?() {
		self.inMemoryDB = DatabaseQueue()
		do {
			try inMemoryDB.write { db in
				try db.create(table: CachedEntry.databaseTableName) { table in
					table.column("itemIdentifier", .text)
					table.column("cloudPath", .text).primaryKey()
				}
			}
			try addOrUpdateIdentifier("root", for: CloudPath("/"))
		} catch {
			return nil
		}
	}

	func addOrUpdateIdentifier(_ identifier: String, for cloudPath: CloudPath) throws {
		try inMemoryDB.write { db in
			if let cachedIdentifier = try CachedEntry.fetchOne(db, key: ["cloudPath": cloudPath]) {
				var updatedCachedIdentifier = cachedIdentifier
				updatedCachedIdentifier.itemIdentifier = identifier
				try updatedCachedIdentifier.updateChanges(db, from: cachedIdentifier)
			} else {
				let newCachedIdentifier = CachedEntry(itemIdentifier: identifier, cloudPath: cloudPath)
				try newCachedIdentifier.insert(db)
			}
		}
	}

	func getCachedIdentifier(for cloudPath: CloudPath) -> String? {
		try? inMemoryDB.read { db in
			let cachedIdentifier = try CachedEntry.fetchOne(db, key: ["cloudPath": cloudPath])
			return cachedIdentifier?.itemIdentifier
		}
	}

	func invalidateIdentifier(for cloudPath: CloudPath) throws {
		try inMemoryDB.write { db in
			if let cachedIdentifier = try CachedEntry.fetchOne(db, key: ["cloudPath": cloudPath]) {
				try cachedIdentifier.delete(db)
			}
		}
	}
}
