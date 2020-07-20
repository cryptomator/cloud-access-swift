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

	/**
	 Convenience wrapper for `deleteItem()` that also satisfies if the item is not present.
	 */
	func deleteItemIfExists(at remoteURL: URL) -> Promise<Void> {
		return deleteItem(at: remoteURL).recover { error -> Promise<Void> in
			switch error {
			case CloudProviderError.itemNotFound:
				return Promise(())
			default:
				return Promise(error)
			}
		}
	}

	/**
	 Checks if the item exists at the given remoteURL.
	 */
	func checkForItemExistence(at remoteURL: URL) -> Promise<Bool> {
		return fetchItemMetadata(at: remoteURL).then { _ in
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
