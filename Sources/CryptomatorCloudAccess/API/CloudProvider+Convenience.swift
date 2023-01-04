//
//  CloudProvider+Convenience.swift
//  CryptomatorCloudAccess
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
	 Convenience wrapper for `downloadFile()` that ignores the underlying task.
	 */
	func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		downloadFile(from: cloudPath, to: localURL, onTaskCreation: nil)
	}

	/**
	 Convenience wrapper for `uploadFile()` that ignores the underlying task.
	 */
	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		uploadFile(from: localURL, to: cloudPath, replaceExisting: replaceExisting, onTaskCreation: nil)
	}

	/**
	 Convenience wrapper for `createFolder()` that also satisfies if the item is present.
	 */
	func createFolderIfMissing(at cloudPath: CloudPath) -> Promise<Void> {
		return createFolder(at: cloudPath).recover { error -> Promise<Void> in
			switch error {
			case CloudProviderError.itemAlreadyExists:
				return Promise(())
			default:
				return Promise(error)
			}
		}
	}

	/**
	 Convenience wrapper for `deleteFile()` that also satisfies if the item is not present.
	 */
	func deleteFileIfExisting(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteFile(at: cloudPath).recover { error -> Promise<Void> in
			switch error {
			case CloudProviderError.itemNotFound:
				return Promise(())
			default:
				return Promise(error)
			}
		}
	}

	/**
	 Convenience wrapper for `deleteFolder()` that also satisfies if the item is not present.
	 */
	func deleteFolderIfExisting(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteFolder(at: cloudPath).recover { error -> Promise<Void> in
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
