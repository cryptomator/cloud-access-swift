//
//  GoogleDriveItem.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 09.07.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

struct GoogleDriveItem: Codable, IdentifierCacheItem, Equatable {
	static let rootItem = GoogleDriveItem(cloudPath: .root, identifier: "root", itemType: .folder, shortcut: nil)
	static let inconsistentCacheError: Error = GoogleDriveError.inconsistentCache
	static let shortcutKey = "shortcut"

	let cloudPath: CloudPath
	let identifier: String
	let itemType: CloudItemType
	let shortcut: GoogleDriveShortcut?
}

extension GoogleDriveItem {
	static func addExtraColumns(to table: TableDefinition) {
		table.column(shortcutKey, .text)
	}

	var resolvedIdentifier: String {
		return shortcut?.targetIdentifier ?? identifier
	}

	/// A shortcut's target's type, `.symlink` for a shortcut without a target type, and otherwise the item's own type. An item without a MIME type stays `.unknown`, even with shortcut details.
	var effectiveItemType: CloudItemType {
		return itemType == .unknown ? .unknown : (shortcut?.targetItemType ?? itemType)
	}

	/// The item's own identifier, not `resolvedIdentifier`, because a delete and a move act on the shortcut itself.
	var changeIdentity: String {
		return identifier
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
