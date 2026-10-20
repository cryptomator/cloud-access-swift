//
//  PCloudItem.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 16.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

struct PCloudItem: Decodable, FetchableRecord, TableRecord, Equatable {
	static let rootFolderID: UInt64 = 0
	static let databaseTableName = "CachedEntries"
	static let cloudPathKey = "cloudPath"
	static let identifierKey = "identifier"
	static let itemTypeKey = "itemType"

	let cloudPath: CloudPath
	let identifier: UInt64
	let itemType: CloudItemType
}

extension PCloudItem {
	init(cloudPath: CloudPath, metadata: PCloudMetadata) throws {
		guard let identifier = metadata.identifier else {
			throw PCloudError.unexpectedContent
		}
		self.cloudPath = cloudPath
		self.identifier = identifier
		self.itemType = metadata.isFolder ? .folder : .file
	}
}

extension PCloudItem: PersistableRecord {
	func encode(to container: inout PersistenceContainer) throws {
		container[PCloudItem.cloudPathKey] = cloudPath
		container[PCloudItem.identifierKey] = identifier
		container[PCloudItem.itemTypeKey] = itemType
	}
}
