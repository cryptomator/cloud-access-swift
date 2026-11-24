//
//  PCloudItem.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 16.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

struct PCloudItem: Decodable, IdentifierCacheItem, Equatable {
	static let rootFolderID: UInt64 = 0
	static let rootItem = PCloudItem(cloudPath: .root, identifier: rootFolderID, itemType: .folder)
	static let inconsistentCacheError: Error = PCloudError.inconsistentCache

	let cloudPath: CloudPath
	let identifier: UInt64
	let itemType: CloudItemType
}

extension PCloudItem {
	/// Includes the type, because pCloud numbers files and folders separately.
	var changeIdentity: String {
		return "\(itemType.rawValue):\(identifier)"
	}

	/// - Throws: `PCloudError.unexpectedContent` if the metadata has no identifier or one above `Int64.max`, which GRDB can't store and would trap on.
	init(cloudPath: CloudPath, metadata: PCloudMetadata) throws {
		guard let identifier = metadata.identifier, identifier <= UInt64(Int64.max) else {
			throw PCloudError.unexpectedContent
		}
		self.cloudPath = cloudPath
		self.identifier = identifier
		self.itemType = metadata.isFolder ? .folder : .file
	}
}

extension PCloudItem {
	func encode(to container: inout PersistenceContainer) throws {
		container[PCloudItem.cloudPathKey] = cloudPath
		container[PCloudItem.identifierKey] = identifier
		container[PCloudItem.itemTypeKey] = itemType
	}
}
