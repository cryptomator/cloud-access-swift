//
//  PCloudIdentifierCache.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 16.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import PCloudSDKSwift

class PCloudIdentifierCache {
	private let inMemoryDB: DatabaseQueue

	init() throws {
		self.inMemoryDB = try DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: PCloudItem.databaseTableName) { table in
				table.column(PCloudItem.cloudPathKey, .text).notNull().primaryKey()
				table.column(PCloudItem.identifierKey, .text).notNull()
				table.column(PCloudItem.itemTypeKey, .text).notNull()
			}
			try PCloudItem(cloudPath: CloudPath("/"), identifier: Folder.root, itemType: .folder).save(db)
		}
	}

	func get(_ cloudPath: CloudPath) -> PCloudItem? {
		try? inMemoryDB.read { db in
			return try PCloudItem.fetchOne(db, key: cloudPath)
		}
	}

	func addOrUpdate(_ item: PCloudItem) throws {
		try inMemoryDB.write { db in
			try item.save(db)
		}
	}

	func invalidate(_ item: PCloudItem) throws {
		try inMemoryDB.write { db in
			try db.execute(sql: "DELETE FROM \(PCloudItem.databaseTableName) WHERE \(PCloudItem.cloudPathKey) LIKE ?", arguments: ["\(item.cloudPath.path)%"])
		}
	}
}
