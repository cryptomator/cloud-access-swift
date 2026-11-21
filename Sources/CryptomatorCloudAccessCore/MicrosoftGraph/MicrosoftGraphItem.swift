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
	static let rootItem = MicrosoftGraphItem(cloudPath: .root, identifier: "root", driveIdentifier: nil, itemType: .folder, isRemoteItem: false)
	static let inconsistentCacheError: Error = MicrosoftGraphError.inconsistentCache
	static let driveIdentifierKey = "driveIdentifier"
	static let isRemoteItemKey = "isRemoteItem"

	let cloudPath: CloudPath
	let identifier: String
	let driveIdentifier: String?
	let itemType: CloudItemType
	/// Whether the item is a remote item (a shared item added to My files), whose identifier and drive identifier are the remote item's. A request by that identifier returns the target without `remoteItem`, so only the cached item tells a download that it reached the target through an alias.
	let isRemoteItem: Bool

	init(cloudPath: CloudPath, identifier: String, driveIdentifier: String?, itemType: CloudItemType, isRemoteItem: Bool) {
		self.cloudPath = cloudPath
		self.identifier = identifier
		self.driveIdentifier = driveIdentifier
		self.itemType = itemType
		self.isRemoteItem = isRemoteItem
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
		self.isRemoteItem = driveItem.remoteItem != nil
	}
}

extension MicrosoftGraphItem {
	static func addExtraColumns(to table: TableDefinition) {
		table.column(driveIdentifierKey, .text)
		table.column(isRemoteItemKey, .boolean).notNull()
	}

	func isSameItem(as other: MicrosoftGraphItem) -> Bool {
		return identifier == other.identifier && MicrosoftGraphItem.isSameDrive(driveIdentifier, other.driveIdentifier) && itemType == other.itemType && isRemoteItem == other.isRemoteItem
	}

	/// Compares drive identifiers exactly, because Graph documents them as case-sensitive. Two OneDrive Personal drive identifiers (15 or 16 hex digits) compare by value instead, because Graph may return one such drive's identifier in either case and without its leading zero.
	private static func isSameDrive(_ driveIdentifier: String?, _ otherDriveIdentifier: String?) -> Bool {
		if driveIdentifier == otherDriveIdentifier {
			return true
		}
		guard let driveIdentifier, let otherDriveIdentifier, let value = personalDriveValue(of: driveIdentifier), let otherValue = personalDriveValue(of: otherDriveIdentifier) else {
			return false
		}
		return value == otherValue
	}

	private static func personalDriveValue(of driveIdentifier: String) -> UInt64? {
		guard driveIdentifier.wholeMatch(of: /[0-9A-Fa-f]{15,16}/) != nil else {
			return nil
		}
		return UInt64(driveIdentifier, radix: 16)
	}

	func encode(to container: inout PersistenceContainer) throws {
		container[MicrosoftGraphItem.cloudPathKey] = cloudPath
		container[MicrosoftGraphItem.identifierKey] = identifier
		container[MicrosoftGraphItem.driveIdentifierKey] = driveIdentifier
		container[MicrosoftGraphItem.itemTypeKey] = itemType
		container[MicrosoftGraphItem.isRemoteItemKey] = isRemoteItem
	}
}
