//
//  CloudItemMetadata.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct CloudItemMetadata: Equatable, Sendable {
	public let name: String
	public let cloudPath: CloudPath
	public let itemType: CloudItemType
	public let lastModifiedDate: Date?
	public let size: Int?
	/// Whether a listing returned the item as a reference to another item (a Google Drive shortcut, a Microsoft Graph remote item), or a download reached it through such a reference. A download counts only a reference at the item itself or at the folder that holds it. A vault folder delete skips a listed alias and refuses a dir file downloaded through one. Metadata reads and uploads never set it.
	let isAlias: Bool

	public init(name: String, cloudPath: CloudPath, itemType: CloudItemType, lastModifiedDate: Date?, size: Int?) {
		self.init(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size, isAlias: false)
	}

	init(name: String, cloudPath: CloudPath, itemType: CloudItemType, lastModifiedDate: Date?, size: Int?, isAlias: Bool) {
		self.name = name
		self.cloudPath = cloudPath
		self.itemType = itemType
		self.lastModifiedDate = lastModifiedDate
		self.size = size
		self.isAlias = isAlias
	}

	/// Compares the public fields only, so that a value compares equal to one rebuilt from them.
	public static func == (lhs: CloudItemMetadata, rhs: CloudItemMetadata) -> Bool {
		return lhs.name == rhs.name && lhs.cloudPath == rhs.cloudPath && lhs.itemType == rhs.itemType && lhs.lastModifiedDate == rhs.lastModifiedDate && lhs.size == rhs.size
	}
}
