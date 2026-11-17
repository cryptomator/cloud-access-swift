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

 A directory that doesn't exist counts as deleted, so that a later delete finishes what a failed one left behind.

 If a subdirectory fails for any reason but cancellation, this directory and the reference to it stay, so that a later delete can finish. The cloud may have refused it, it may exist but not be listable, or reading its dir ID or a request may have failed. The delete still goes on with the other subdirectories and pages.

 A subfolder that the listing leaves out isn't deleted, e.g., one whose name file is invalid, or is missing while another item of its page is restored. Its directory stays without a reference, as with the directory delete of Cryptomator Desktop. Desktop's health check reports such a directory as an orphan and recovers its contents.

 - Parameter subdirectoryIds: Returns the dir IDs that an item of the directory refers to, none for an item that isn't a subdirectory.
 - Parameter deleteSubdirectory: Deletes the ciphertext directory of a dir ID.
 - Throws: The highest-ranked failure of the subdirectories and of the directory's own listing and delete, the first one on a tie: `CloudProviderError.deletionIncomplete` if the cloud refused to delete something. Otherwise `CloudProviderError.itemNotFound` if a directory exists but can't be listed, e.g., because a name file is missing. A subdirectory's `CloudProviderError.itemTypeMismatch` counts as such, so `itemTypeMismatch` is thrown only if the directory itself isn't a folder.
 */
func deleteCiphertextDirectory(at dirPath: CloudPath, of provider: CloudProvider, subdirectoryIds: @escaping @Sendable (CloudItemMetadata) async throws -> [Data], deleteSubdirectory: @escaping @Sendable (Data) async throws -> Void) async throws {
	var failure: Error?
	var pageToken: String?
	repeat {
		let itemList: CloudItemList
		do {
			itemList = try await provider.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		} catch CloudProviderError.itemNotFound where pageToken == nil {
			// A listing also fails with `itemNotFound` for a name file that is missing, so only the directory's own absence counts as deleted.
			if try await provider.checkForItemExistence(at: dirPath) {
				throw CloudProviderError.itemNotFound
			}
			return
		} catch where !(error is CancellationError) {
			throw prevailingFailure(failure, error)
		}
		let itemFailures = try await mapConcurrently(itemList.items, limit: vaultItemConcurrencyLimit) { item -> Error? in
			do {
				for dirId in try await subdirectoryIds(item) {
					try await deleteSubdirectory(dirId)
				}
				return nil
			} catch CloudProviderError.itemTypeMismatch {
				// VF7's `deleteFolder` deletes the `.c9r` of a folder whose own directory throws `itemTypeMismatch`, so a subdirectory's must not reach it.
				return CloudProviderError.itemNotFound
			} catch where !(error is CancellationError) {
				return error
			}
		}
		for case let itemFailure? in itemFailures {
			failure = prevailingFailure(failure, itemFailure)
		}
		pageToken = itemList.nextPageToken
	} while pageToken != nil
	if let failure {
		throw failure
	}
	do {
		try await provider.deleteFolder(at: dirPath)
	} catch CloudProviderError.itemNotFound {
		// The directory disappeared after it was listed, or the provider listed a missing folder as empty. Either way it counts as deleted.
	}
}

/// Returns the failure that `deleteCiphertextDirectory` throws of the two, keeping `recorded` on a tie. A refusal ranks highest, then a directory that exists but can't be listed, then any other failure.
private func prevailingFailure(_ recorded: Error?, _ new: Error) -> Error {
	guard let recorded, rank(of: recorded) <= rank(of: new) else {
		return new
	}
	return recorded
}

private func rank(of failure: Error) -> Int {
	switch failure {
	case CloudProviderError.deletionIncomplete:
		return 0
	case CloudProviderError.itemNotFound:
		return 1
	default:
		return 2
	}
}
