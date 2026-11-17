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

 If the cloud refused to delete a subdirectory, this directory and the reference to it stay, so that a later delete can finish. They also stay if a subdirectory exists but can't be listed. Any later failure but cancellation then throws `deletionIncomplete` if a subdirectory was refused, and `itemNotFound` otherwise. Otherwise an ancestor could skip the failure, because a sibling was deleted, and delete the reference to this directory.

 A subfolder that the listing leaves out isn't deleted, e.g., one whose name file is invalid, or is missing while another item of its page is restored. Its directory stays without a reference, as with the directory delete of Cryptomator Desktop. Desktop's health check reports such a directory as an orphan and recovers its contents.

 - Parameter subdirectoryIds: Returns the dir IDs of the subdirectories that a page of the directory lists.
 - Parameter deleteSubdirectory: Deletes the ciphertext directory of a dir ID, throwing `CloudProviderError.deletionIncomplete` if the cloud refused part of it and `CloudProviderError.itemNotFound` if it or a directory below it exists but can't be listed.
 - Throws: `CloudProviderError.deletionIncomplete` if the cloud refused to delete a subdirectory or the directory itself. Otherwise `CloudProviderError.itemNotFound` if the directory or a subdirectory exists but can't be listed, e.g., because a name file is missing. Otherwise the error of the last failed subdirectory of a page of which none was deleted, as `allSettled` does.
 */
func deleteCiphertextDirectory(at dirPath: CloudPath, of provider: CloudProvider, subdirectoryIds: (CloudItemList) async throws -> [Data], deleteSubdirectory: @escaping @Sendable (Data) async throws -> Void) async throws {
	var subdirectoryFailure: CloudProviderError?
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
			let failures = try await allSettled(subdirectoryIds(itemList), limit: vaultItemConcurrencyLimit) { dirId -> CloudProviderError? in
				do {
					try await deleteSubdirectory(dirId)
					return nil
				} catch CloudProviderError.deletionIncomplete {
					return .deletionIncomplete
				} catch CloudProviderError.itemNotFound {
					return .itemNotFound
				}
			}
			if failures.contains(.deletionIncomplete) {
				subdirectoryFailure = .deletionIncomplete
			} else if failures.contains(.itemNotFound), subdirectoryFailure == nil {
				subdirectoryFailure = .itemNotFound
			}
			pageToken = itemList.nextPageToken
		} catch where !(error is CancellationError) {
			throw subdirectoryFailure ?? error
		}
	} while pageToken != nil
	if let subdirectoryFailure {
		throw subdirectoryFailure
	}
	do {
		try await provider.deleteFolder(at: dirPath)
	} catch CloudProviderError.itemNotFound {
		// The directory disappeared after it was listed, or the provider listed a missing folder as empty. Either way it counts as deleted.
	}
}
