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
				table.column(OneDriveItem.cloudPathKey, .text).notNull().primaryKey()
				table.column(OneDriveItem.identifierKey, .text).notNull()
				table.column(OneDriveItem.driveIdentifierKey, .text)
				table.column(OneDriveItem.itemTypeKey, .text).notNull()
			}
			try OneDriveItem(cloudPath: CloudPath("/"), identifier: "root", driveIdentifier: nil, itemType: .folder).save(db)
		}
	}

	func get(_ cloudPath: CloudPath) -> OneDriveItem? {
		try? inMemoryDB.read { db in
			return try OneDriveItem.fetchOne(db, key: cloudPath)
		}
	}

	func addOrUpdate(_ item: OneDriveItem) throws {
		try inMemoryDB.write { db in
			try item.save(db)
		}
	}

	func invalidate(_ item: OneDriveItem) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(OneDriveItem.databaseTableName) WHERE \(OneDriveItem.cloudPathKey) LIKE ?", arguments: ["\(item.cloudPath.path)%"])
		}
	}
}
