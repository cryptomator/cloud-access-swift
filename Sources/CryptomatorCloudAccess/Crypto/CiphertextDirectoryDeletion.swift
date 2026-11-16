//
//  CiphertextDirectoryDeletion.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 16.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Deletes a vault's ciphertext directory. It deletes the directories of its subdirectories page by page, those of a page concurrently, and then the directory itself. Must run inside `withoutCancellation`, because stopping halfway leaves folders whose directory is missing.

 A directory that doesn't exist counts as deleted, so that a later delete finishes what a refused one left behind.

 If the cloud refused to delete a subdirectory, this directory and the reference to it stay, so that a later delete can finish. Any later failure but cancellation then throws `deletionIncomplete` as well. Otherwise an ancestor could skip the failure, because a sibling was deleted, and delete the reference to this directory.

 - Parameter subdirectoryIds: Returns the dir IDs of the subdirectories that a page of the directory lists.
 - Parameter deleteSubdirectory: Deletes the ciphertext directory of a dir ID, throwing `CloudProviderError.deletionIncomplete` if the cloud refused part of it.
 - Throws: `CloudProviderError.deletionIncomplete` if the cloud refused to delete a subdirectory or the directory itself. `CloudProviderError.itemNotFound` if the directory exists but can't be listed, e.g., because a name file is missing. Without a refusal, the error of the last failed subdirectory of a page of which none was deleted, as `allSettled` does.
 */
func deleteCiphertextDirectory(at dirPath: CloudPath, of provider: CloudProvider, subdirectoryIds: (CloudItemList) async throws -> [Data], deleteSubdirectory: @escaping @Sendable (Data) async throws -> Void) async throws {
	var isSubdirectoryRefused = false
	var pageToken: String?
	repeat {
		do {
			let itemList: CloudItemList
			do {
				itemList = try await provider.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
			} catch CloudProviderError.itemNotFound where pageToken == nil {
				// A listing also fails with `itemNotFound` for a name file that is missing, so only the directory's own absence counts as deleted.
				if try await provider.checkForItemExistence(at: dirPath) {
					throw CloudProviderError.itemNotFound
				}
				return
			}
			let isRefused = try await allSettled(subdirectoryIds(itemList)) { dirId in
				do {
					try await deleteSubdirectory(dirId)
					return false
				} catch CloudProviderError.deletionIncomplete {
					return true
				}
			}.contains(true)
			if isRefused {
				isSubdirectoryRefused = true
			}
			pageToken = itemList.nextPageToken
		} catch where isSubdirectoryRefused && !(error is CancellationError) {
			throw CloudProviderError.deletionIncomplete
		}
	} while pageToken != nil
	if isSubdirectoryRefused {
		throw CloudProviderError.deletionIncomplete
	}
	do {
		try await provider.deleteFolder(at: dirPath)
	} catch CloudProviderError.itemNotFound {
		// The directory disappeared after it was listed, or the provider listed a missing folder as empty. Either way it counts as deleted.
	}
}
