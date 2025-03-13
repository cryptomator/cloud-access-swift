//
//  MicrosoftGraphIdentifierCache.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 20.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

class MicrosoftGraphIdentifierCache {
	private let inMemoryDB: DatabaseQueue

	init() throws {
		self.inMemoryDB = try DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: MicrosoftGraphItem.databaseTableName) { table in
				table.column(MicrosoftGraphItem.cloudPathKey, .text).notNull().primaryKey()
				table.column(MicrosoftGraphItem.identifierKey, .text).notNull()
				table.column(MicrosoftGraphItem.driveIdentifierKey, .text)
				table.column(MicrosoftGraphItem.itemTypeKey, .text).notNull()
			}
			try MicrosoftGraphItem(cloudPath: CloudPath("/"), identifier: "root", driveIdentifier: nil, itemType: .folder).save(db)
		}
	}

	func get(_ cloudPath: CloudPath) -> MicrosoftGraphItem? {
		try? inMemoryDB.read { db in
			return try MicrosoftGraphItem.fetchOne(db, key: cloudPath)
		}
	}

	func addOrUpdate(_ item: MicrosoftGraphItem) throws {
		try inMemoryDB.write { db in
			try item.save(db)
		}
	}

	func invalidate(_ item: MicrosoftGraphItem) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(MicrosoftGraphItem.databaseTableName) WHERE \(MicrosoftGraphItem.cloudPathKey) LIKE ?", arguments: ["\(item.cloudPath.path)%"])
		}
	}
}
