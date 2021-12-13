//
//  GoogleDriveItem.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 09.07.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import GoogleAPIClientForREST_Drive
import GRDB

struct GoogleDriveItem: Decodable, FetchableRecord, TableRecord, Equatable {
	static let databaseTableName = "CachedEntries"
	static let cloudPathKey = "cloudPath"
	static let identifierKey = "identifier"
	static let itemTypeKey = "itemType"

	let cloudPath: CloudPath
	let identifier: String
	let itemType: CloudItemType

	init(cloudPath: CloudPath, identifier: String, itemType: CloudItemType) {
		self.cloudPath = cloudPath
		self.identifier = identifier
		self.itemType = itemType
	}

	init(cloudPath: CloudPath, file: GTLRDrive_File) throws {
		self.cloudPath = cloudPath
		guard let identifier = file.identifier else {
			throw GoogleDriveError.identifierNotFound
		}
		self.identifier = identifier
		self.itemType = file.getCloudItemType()
	}
}

extension GoogleDriveItem: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container[GoogleDriveItem.cloudPathKey] = cloudPath
		container[GoogleDriveItem.identifierKey] = identifier
		container[GoogleDriveItem.itemTypeKey] = itemType
	}
}
