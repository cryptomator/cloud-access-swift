//
//  CloudItemMetadata.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct CloudItemMetadata {
	let name: String
	let remoteURL: URL
	let itemType: CloudItemType
	let lastModifiedDate: Date?
	let size: Int?
}
