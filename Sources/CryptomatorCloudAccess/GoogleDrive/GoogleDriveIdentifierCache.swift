//
//  GoogleDriveIdentifierCache.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 11.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

class GoogleDriveIdentifierCache {
	private let inMemoryDB: DatabaseQueue

	init() throws {
		self.inMemoryDB = DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: GoogleDriveItem.databaseTableName) { table in
				table.column(GoogleDriveItem.cloudPathKey, .text).notNull().primaryKey()
				table.column(GoogleDriveItem.identifierKey, .text).notNull()
				table.column(GoogleDriveItem.itemTypeKey, .text).notNull()
				table.column(GoogleDriveItem.shortcutKey, .text)
			}
			try GoogleDriveItem(cloudPath: CloudPath("/"), identifier: "root", itemType: .folder, shortcut: nil).save(db)
		}
	}

	func get(_ cloudPath: CloudPath) -> GoogleDriveItem? {
		try? inMemoryDB.read { db in
			return try GoogleDriveItem.fetchOne(db, key: cloudPath)
		}
	}

	func addOrUpdate(_ item: GoogleDriveItem) throws {
		try inMemoryDB.write { db in
			try item.save(db)
		}
	}

	func invalidate(_ item: GoogleDriveItem) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(GoogleDriveItem.databaseTableName) WHERE \(GoogleDriveItem.cloudPathKey) LIKE ?", arguments: ["\(item.cloudPath.path)%"])
		}
	}
}
