//
//  MicrosoftGraphItem.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 19.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

struct MicrosoftGraphItem: Decodable, IdentifierCacheItem, Equatable {
	static let rootItem = MicrosoftGraphItem(cloudPath: CloudPath("/"), identifier: "root", driveIdentifier: nil, itemType: .folder)
	static let inconsistentCacheError: Error = MicrosoftGraphError.inconsistentCache
	static let driveIdentifierKey = "driveIdentifier"

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

	init(cloudPath: CloudPath, driveItem: MicrosoftGraphAPI.DriveItem) {
		self.cloudPath = cloudPath
		self.identifier = driveItem.remoteItem?.id ?? driveItem.id
		if let remoteDriveId = driveItem.remoteItem?.parentReference?.driveId {
			self.driveIdentifier = remoteDriveId
		} else {
			self.driveIdentifier = driveItem.parentReference?.driveId
		}
		self.itemType = driveItem.cloudItemType
	}
}

extension MicrosoftGraphItem {
	static func addExtraColumns(to table: TableDefinition) {
		table.column(driveIdentifierKey, .text)
	}

	func encode(to container: inout PersistenceContainer) throws {
		container[MicrosoftGraphItem.cloudPathKey] = cloudPath
		container[MicrosoftGraphItem.identifierKey] = identifier
		container[MicrosoftGraphItem.driveIdentifierKey] = driveIdentifier
		container[MicrosoftGraphItem.itemTypeKey] = itemType
	}
}
