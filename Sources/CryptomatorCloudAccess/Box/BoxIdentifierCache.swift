//
//  BoxIdentifierCache.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import BoxSDK
import Foundation
import GRDB

class BoxIdentifierCache {
	private let inMemoryDB: DatabaseQueue

	init() throws {
		self.inMemoryDB = DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: BoxItem.databaseTableName) { table in
				table.column(BoxItem.cloudPathKey, .text).notNull().primaryKey()
				table.column(BoxItem.identifierKey, .text).notNull()
				table.column(BoxItem.itemTypeKey, .text).notNull()
			}
			try BoxItem(cloudPath: CloudPath("/"), identifier: "0", itemType: .folder).save(db)
		}
	}

	func get(_ cloudPath: CloudPath) -> BoxItem? {
		try? inMemoryDB.read { db in
			return try BoxItem.fetchOne(db, key: cloudPath)
		}
	}

	func addOrUpdate(_ item: BoxItem) throws {
		try inMemoryDB.write { db in
			try item.save(db)
		}
	}

	func invalidate(_ item: BoxItem) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(BoxItem.databaseTableName) WHERE \(BoxItem.cloudPathKey) LIKE ?", arguments: ["\(item.cloudPath.path)%"])
		}
	}
}
