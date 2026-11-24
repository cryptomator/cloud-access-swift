//
//  BoxItem.swift
//  CryptomatorCloudAccessCore
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

struct BoxItem: Decodable, IdentifierCacheItem, Equatable {
	static let rootItem = BoxItem(cloudPath: .root, identifier: "0", itemType: .folder)
	static let inconsistentCacheError: Error = BoxError.inconsistentCache

	let cloudPath: CloudPath
	let identifier: String
	let itemType: CloudItemType
}

extension BoxItem {
	/// Includes the type, because Box addresses files and folders through separate endpoints and doesn't document their IDs as distinct.
	var changeIdentity: String {
		return "\(itemType.rawValue):\(identifier)"
	}

	/// - Throws: `BoxError.unexpectedContent` if the entry is neither a file nor a folder.
	init(cloudPath: CloudPath, entry: BoxEntry) throws {
		self.cloudPath = cloudPath
		self.identifier = entry.id
		guard let itemType = entry.itemType else {
			throw BoxError.unexpectedContent
		}
		self.itemType = itemType
	}
}

extension BoxItem {
	func encode(to container: inout PersistenceContainer) throws {
		container[BoxItem.cloudPathKey] = cloudPath
		container[BoxItem.identifierKey] = identifier
		container[BoxItem.itemTypeKey] = itemType
	}
}
