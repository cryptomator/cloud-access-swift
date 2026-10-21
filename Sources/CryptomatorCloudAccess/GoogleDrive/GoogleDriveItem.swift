//
//  GoogleDriveItem.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 09.07.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

struct GoogleDriveItem: Codable, PersistableRecord, FetchableRecord, Equatable {
	static let databaseTableName = "CachedEntries"
	static let cloudPathKey = "cloudPath"
	static let identifierKey = "identifier"
	static let itemTypeKey = "itemType"
	static let shortcutKey = "shortcut"

	let cloudPath: CloudPath
	let identifier: String
	let itemType: CloudItemType
	let shortcut: GoogleDriveShortcut?
}

extension GoogleDriveItem {
	var resolvedIdentifier: String {
		return shortcut?.targetIdentifier ?? identifier
	}

	var resolvedItemType: CloudItemType {
		return shortcut?.targetItemType ?? itemType
	}

	init(cloudPath: CloudPath, file: GoogleDriveFile) throws {
		self.cloudPath = cloudPath
		guard let identifier = file.id else {
			throw GoogleDriveError.identifierNotFound
		}
		self.identifier = identifier
		self.itemType = file.cloudItemType
		if let targetIdentifier = file.shortcutDetails?.targetId, let targetMimeType = file.shortcutDetails?.targetMimeType {
			self.shortcut = GoogleDriveShortcut(targetIdentifier: targetIdentifier, targetItemType: GoogleDriveJSON.cloudItemType(ofMimeType: targetMimeType))
		} else {
			self.shortcut = nil
		}
	}
}

struct GoogleDriveShortcut: Codable, Equatable {
	let targetIdentifier: String
	let targetItemType: CloudItemType
}
