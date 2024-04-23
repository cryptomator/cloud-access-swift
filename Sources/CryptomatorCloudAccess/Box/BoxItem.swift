//
//  BoxItem.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import BoxSDK
import Foundation
import GRDB

struct BoxItem: Decodable, FetchableRecord, TableRecord, Equatable {
	static let databaseTableName = "CachedEntries"
	static let cloudPathKey = "cloudPath"
	static let identifierKey = "identifier"
	static let itemTypeKey = "itemType"

	let cloudPath: CloudPath
	let identifier: String
	let itemType: CloudItemType
}

extension BoxItem {
	init(cloudPath: CloudPath, folderItem: FolderItem) throws {
		switch folderItem {
		case let .file(file):
			self.init(cloudPath: cloudPath, file: file)
		case let .folder(folder):
			self.init(cloudPath: cloudPath, folder: folder)
		case let .webLink(webLink):
			throw BoxError.unexpectedContent
		}
	}

	init(cloudPath: CloudPath, file: File) {
		self.cloudPath = cloudPath
		self.identifier = file.id
		self.itemType = .file
	}

	init(cloudPath: CloudPath, folder: Folder) {
		self.cloudPath = cloudPath
		self.identifier = folder.id
		self.itemType = .folder
	}
}

extension BoxItem: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container[BoxItem.cloudPathKey] = cloudPath
		container[BoxItem.identifierKey] = identifier
		container[BoxItem.itemTypeKey] = itemType
	}
}
