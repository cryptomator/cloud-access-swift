//
//  CloudProvider+Convenience.swift
//  CloudAccess
//
//  Created by Sebastian Stenzel on 26.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

extension CloudProvider {
	/**
	 Convenience wrapper for `fetchItemList()` that returns a complete item list.
	 */
	internal func fetchItemListExhaustively(forFolderAt cleartextURL: URL, appendTo itemList: CloudItemList = CloudItemList(items: [])) -> Promise<CloudItemList> {
		return fetchItemList(forFolderAt: cleartextURL, withPageToken: itemList.nextPageToken).then { nextItems -> Promise<CloudItemList> in
			let combinedList = itemList + nextItems
			if combinedList.nextPageToken == nil {
				return Promise(combinedList)
			} else {
				return self.fetchItemListExhaustively(forFolderAt: cleartextURL, appendTo: combinedList)
			}
		}
	}
}
