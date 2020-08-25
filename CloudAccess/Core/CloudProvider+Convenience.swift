//
//  CloudProvider+Convenience.swift
//  CloudAccess
//
//  Created by Sebastian Stenzel on 26.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

public extension CloudProvider {
	/**
	 Convenience wrapper for `fetchItemList()` that returns a complete item list.
	 */
	func fetchItemListExhaustively(forFolderAt cloudPath: CloudPath, appendTo itemList: CloudItemList = CloudItemList(items: [])) -> Promise<CloudItemList> {
		return fetchItemList(forFolderAt: cloudPath, withPageToken: itemList.nextPageToken).then { nextItems -> Promise<CloudItemList> in
			let combinedList = itemList + nextItems
			if combinedList.nextPageToken == nil {
				return Promise(combinedList)
			} else {
				return self.fetchItemListExhaustively(forFolderAt: cloudPath, appendTo: combinedList)
			}
		}
	}

	/**
	 Convenience wrapper for `deleteItem()` that also satisfies if the item is not present.
	 */
	func deleteItemIfExists(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath).recover { error -> Promise<Void> in
			switch error {
			case CloudProviderError.itemNotFound:
				return Promise(())
			default:
				return Promise(error)
			}
		}
	}

	/**
	 Checks if the item exists at the given cloud path.
	 */
	func checkForItemExistence(at cloudPath: CloudPath) -> Promise<Bool> {
		return fetchItemMetadata(at: cloudPath).then { _ in
			return Promise(true)
		}.recover { error -> Promise<Bool> in
			switch error {
			case CloudProviderError.itemNotFound:
				return Promise(false)
			default:
				return Promise(error)
			}
		}
	}
}
