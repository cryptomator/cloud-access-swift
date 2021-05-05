//
//  OneDriveIdentifierCache.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 20.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
class OneDriveIdentifierCache {
	private let inMemoryDB: DatabaseQueue

	init() throws {
		self.inMemoryDB = DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: OneDriveItem.databaseTableName) { table in
				table.column(OneDriveItem.pathKey, .text).primaryKey()
				table.column(OneDriveItem.identifierKey, .text).notNull()
				table.column(OneDriveItem.driveIdentifierKey, .text)
				table.column(OneDriveItem.itemTypeKey, .text).notNull()
			}
		}
		let rootItem = OneDriveItem(path: CloudPath("/"), itemIdentifier: "root", driveIdentifier: nil, itemType: .folder)
		try addOrUpdate(rootItem)
	}

	func addOrUpdate(_ item: OneDriveItem) throws {
		try inMemoryDB.write { db in
			try item.save(db)
		}
	}

	func getCachedItem(for cloudPath: CloudPath) -> OneDriveItem? {
		try? inMemoryDB.read { db in
			let cachedItem = try OneDriveItem.fetchOne(db, key: [OneDriveItem.pathKey: cloudPath])
			return cachedItem
		}
	}

	func remove(_ item: OneDriveItem) throws {
		try inMemoryDB.write { db in
			try item.delete(db)
		}
	}
}
