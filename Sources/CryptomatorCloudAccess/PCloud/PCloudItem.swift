//
//  PCloudItem.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 16.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import PCloudSDKSwift

struct PCloudItem: Decodable, FetchableRecord, TableRecord, Equatable {
	static let databaseTableName = "CachedEntries"
	static let cloudPathKey = "cloudPath"
	static let identifierKey = "identifier"
	static let itemTypeKey = "itemType"

	let cloudPath: CloudPath
	let identifier: UInt64
	let itemType: CloudItemType
}

extension PCloudItem {
	init(cloudPath: CloudPath, content: Content) throws {
		self.cloudPath = cloudPath
		if let fileMetadata = content.fileMetadata {
			self.identifier = fileMetadata.id
			self.itemType = .file
		} else if let folderMetadata = content.folderMetadata {
			self.identifier = folderMetadata.id
			self.itemType = .folder
		} else {
			throw PCloudError.unexpectedContent
		}
	}

	init(cloudPath: CloudPath, metadata: File.Metadata) {
		self.cloudPath = cloudPath
		self.identifier = metadata.id
		self.itemType = .file
	}

	init(cloudPath: CloudPath, metadata: Folder.Metadata) {
		self.cloudPath = cloudPath
		self.identifier = metadata.id
		self.itemType = .folder
	}
}

extension PCloudItem: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container[PCloudItem.cloudPathKey] = cloudPath
		container[PCloudItem.identifierKey] = identifier
		container[PCloudItem.itemTypeKey] = itemType
	}
}
