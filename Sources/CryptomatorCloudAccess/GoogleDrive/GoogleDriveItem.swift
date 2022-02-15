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
	init(cloudPath: CloudPath, file: GTLRDrive_File) throws {
		self.cloudPath = cloudPath
		guard let identifier = file.identifier else {
			throw GoogleDriveError.identifierNotFound
		}
		self.identifier = identifier
		self.itemType = file.getCloudItemType()
		if let shortcutDetailsTargetId = file.shortcutDetails?.targetId, let shortcutDetailsTargetMimeType = file.shortcutDetails?.targetMimeType {
			self.shortcut = GoogleDriveShortcut(targetIdentifier: shortcutDetailsTargetId, targetItemType: shortcutDetailsTargetMimeType.convertGoogleDriveMimeTypeToCloudItemType())
		} else {
			self.shortcut = nil
		}
	}
}

struct GoogleDriveShortcut: Codable, Equatable {
	let targetIdentifier: String
	let targetItemType: CloudItemType
}
