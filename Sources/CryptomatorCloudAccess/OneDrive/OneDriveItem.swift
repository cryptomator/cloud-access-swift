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

struct OneDriveItem: Decodable, FetchableRecord, TableRecord, Equatable {
	static let databaseTableName = "CachedEntries"
	static let cloudPathKey = "cloudPath"
	static let identifierKey = "identifier"
	static let driveIdentifierKey = "driveIdentifier"
	static let itemTypeKey = "itemType"

	let cloudPath: CloudPath
	let identifier: String
	let driveIdentifier: String?
	let itemType: CloudItemType

	init(cloudPath: CloudPath, identifier: String, driveIdentifier: String?, itemType: CloudItemType) {
		self.cloudPath = cloudPath
		self.identifier = identifier
		self.driveIdentifier = driveIdentifier
		self.itemType = itemType
	}

	init(cloudPath: CloudPath, driveItem: MSGraphDriveItem) {
		self.cloudPath = cloudPath
		self.identifier = driveItem.remoteItem?.remoteItemId ?? driveItem.entityId
		if let remoteDriveId = driveItem.remoteItem?.parentReference?.driveId {
			self.driveIdentifier = remoteDriveId
		} else {
			self.driveIdentifier = driveItem.parentReference?.driveId
		}
		self.itemType = driveItem.getCloudItemType()
	}
}

extension OneDriveItem: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container[OneDriveItem.cloudPathKey] = cloudPath
		container[OneDriveItem.identifierKey] = identifier
		container[OneDriveItem.driveIdentifierKey] = driveIdentifier
		container[OneDriveItem.itemTypeKey] = itemType
	}
}
