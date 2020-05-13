//
//  CloudItemMetadata.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct CloudItemMetadata {
	public let name: String
	public let remoteURL: URL
	public let itemType: CloudItemType
	public let lastModifiedDate: Date?
	public let size: NSNumber?

	public init(name: String, remoteURL: URL, itemType: CloudItemType, lastModifiedDate: Date?, size: NSNumber?) {
		self.name = name
		self.remoteURL = remoteURL
		self.itemType = itemType
		self.lastModifiedDate = lastModifiedDate
		self.size = size
	}
}
