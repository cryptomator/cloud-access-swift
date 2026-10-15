//
//  CloudProvider+Convenience.swift
//  CryptomatorCloudAccess
//
//  Created by Sebastian Stenzel on 26.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public extension CloudProvider {
	/**
	 Convenience wrapper for `fetchItemList()` that returns a complete item list.
	 */
	@concurrent
	func fetchItemListExhaustively(forFolderAt cloudPath: CloudPath, appendTo itemList: CloudItemList = CloudItemList(items: [])) async throws -> CloudItemList {
		var combinedList = itemList
		repeat {
			combinedList = try await combinedList + fetchItemList(forFolderAt: cloudPath, withPageToken: combinedList.nextPageToken)
		} while combinedList.nextPageToken != nil
		return combinedList
	}

	/**
	 Convenience wrapper for `downloadFile()` that ignores the progress and the underlying task.
	 */
	@concurrent
	func downloadFile(from cloudPath: CloudPath, to localURL: URL) async throws -> CloudItemMetadata {
		try await downloadFile(from: cloudPath, to: localURL, progress: nil, onTaskCreation: nil)
	}

	/**
	 Convenience wrapper for `uploadFile()` that ignores the progress and the underlying task.
	 */
	@concurrent
	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) async throws -> CloudItemMetadata {
		try await uploadFile(from: localURL, to: cloudPath, replaceExisting: replaceExisting, progress: nil, onTaskCreation: nil)
	}

	/**
	 Convenience wrapper for `createFolder()` that also satisfies if the item is present.
	 */
	@concurrent
	func createFolderIfMissing(at cloudPath: CloudPath) async throws {
		do {
			try await createFolder(at: cloudPath)
		} catch CloudProviderError.itemAlreadyExists {
			return
		}
	}

	/**
	 Convenience wrapper for `deleteFile()` that also satisfies if the item is not present.
	 */
	@concurrent
	func deleteFileIfExisting(at cloudPath: CloudPath) async throws {
		do {
			try await deleteFile(at: cloudPath)
		} catch CloudProviderError.itemNotFound {
			return
		}
	}

	/**
	 Convenience wrapper for `deleteFolder()` that also satisfies if the item is not present.
	 */
	@concurrent
	func deleteFolderIfExisting(at cloudPath: CloudPath) async throws {
		do {
			try await deleteFolder(at: cloudPath)
		} catch CloudProviderError.itemNotFound {
			return
		}
	}

	/**
	 Checks if the item exists at the given cloud path.
	 */
	@concurrent
	func checkForItemExistence(at cloudPath: CloudPath) async throws -> Bool {
		do {
			_ = try await fetchItemMetadata(at: cloudPath)
			return true
		} catch CloudProviderError.itemNotFound {
			return false
		}
	}
}
