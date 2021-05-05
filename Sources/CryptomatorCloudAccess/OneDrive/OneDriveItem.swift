//
//  OneDriveItem.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 19.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import MSGraphClientModels

struct OneDriveItem: Decodable, FetchableRecord, TableRecord {
	let itemIdentifier: String
	let driveIdentifier: String?
	let path: CloudPath
	let itemType: CloudItemType

	static let databaseTableName = "cachedEntries"
	static let pathKey = "path"
	static let identifierKey = "itemIdentifier"
	static let driveIdentifierKey = "driveIdentifier"
	static let itemTypeKey = "itemType"

	init(path: CloudPath, itemIdentifier: String, driveIdentifier: String?, itemType: CloudItemType) {
		self.path = path
		self.itemIdentifier = itemIdentifier
		self.driveIdentifier = driveIdentifier
		self.itemType = itemType
	}

	init(path: CloudPath, item: MSGraphDriveItem) {
		self.path = path
		self.itemIdentifier = item.remoteItem?.remoteItemId ?? item.entityId
		if let remoteDriveId = item.remoteItem?.parentReference?.driveId {
			self.driveIdentifier = remoteDriveId
		} else {
			self.driveIdentifier = item.parentReference?.driveId
		}
		self.itemType = item.getCloudItemType()
	}
}

extension OneDriveItem: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container[OneDriveItem.pathKey] = path
		container[OneDriveItem.identifierKey] = itemIdentifier
		container[OneDriveItem.driveIdentifierKey] = driveIdentifier
		container[OneDriveItem.itemTypeKey] = itemType
	}
}
