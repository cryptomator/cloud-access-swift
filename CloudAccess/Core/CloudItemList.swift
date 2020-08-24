//
//  CloudItemList.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct CloudItemList {
	let items: [CloudItemMetadata]
	let nextPageToken: String?

	public init(items: [CloudItemMetadata], nextPageToken: String? = nil) {
		self.items = items
		self.nextPageToken = nextPageToken
	}

	static func + (left: CloudItemList, right: CloudItemList) -> CloudItemList {
		return CloudItemList(items: left.items + right.items, nextPageToken: right.nextPageToken)
	}
}
