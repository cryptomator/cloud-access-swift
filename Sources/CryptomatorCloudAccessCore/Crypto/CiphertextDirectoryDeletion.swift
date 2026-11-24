//
//  CiphertextDirectoryDeletion.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 16.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

/**
 Stops a vault folder delete at every level once any of its requests failed with `CloudProviderError.unauthorized`, `CloudProviderError.noInternetConnection` or a Dropbox 401 for a suspended account. The delete takes them for an account-wide or offline failure, after which further requests would most likely fail too. Some providers also report a refusal of a single item as `unauthorized` (S3, when a policy denies reading or listing a key), so a sibling that could have succeeded is left to a later delete.

 One stop serves a whole delete, because a level returns only its highest-ranked failure, which can hide a stopping error of a nested level. An item that was admitted before the stop still finishes resolving its dir IDs.
 */
final class CiphertextDirectoryDeletionStop: Sendable {
	struct Events: Sendable {
		/// Runs once, when the stopping error is recorded.
		var didRecord: @Sendable (Error) -> Void = { _ in }
	}

	private let recordedError = OSAllocatedUnfairLock<Error?>(initialState: nil)
	private let events: Events

	init(events: Events = Events()) {
		self.events = events
	}

	/// The first stopping error that was observed, if any.
	var error: Error? {
		return recordedError.withLock { $0 }
	}

	/// Records the error if it is the first stopping error.
	func observe(_ error: Error) {
		guard isStoppingFailure(error) else {
			return
		}
		let isRecorded = recordedError.withLock { recordedError in
			guard recordedError == nil else {
				return false
			}
			recordedError = error
			return true
		}
		if isRecorded {
			events.didRecord(error)
		}
	}

	func observing<Value>(_ operation: () async throws -> Value) async throws -> Value {
		do {
			return try await operation()
		} catch {
			observe(error)
			throw error
		}
	}
}

/**
 Deletes a vault's ciphertext directories. It deletes the directories of a directory's subdirectories page by page, those of a page concurrently, and then the directory itself.

 A directory that doesn't exist counts as deleted, so that a later delete finishes what a failed one left behind. If the directory's path holds a file, its first listing throws `CloudProviderError.itemTypeMismatch`. If the path's metadata then reports a file, the file is deleted as Cryptomator Desktop deletes it, and it counts as deleted once the path is gone. Otherwise the path counts as a directory that exists but can't be listed (`CloudProviderError.itemNotFound`).

 If a subdirectory fails for any reason but cancellation, its parent directory and the reference to it stay, so that a later delete can finish. The cloud may have refused it, it may exist but not be listable, or reading its dir ID or a request may have failed. The delete still goes on with the other subdirectories and pages.

 An error that stops the delete (see `CiphertextDirectoryDeletionStop`) ends that: no level fetches another page or admits another item, and every directory with skipped work below it stays.

 A dir ID of the vault root, of a folder that contains the deleted one, or of a directory on the recursion path fails its item with `VaultFormatError.invalidDirectoryReference` instead of being followed, because following it would delete a directory that the delete must keep, or loop forever.

 An item that the provider's listing marks as an alias (a shortcut to another item) is never followed, because its target need not lie inside the deleted folder. It goes with its directory.
 */
struct CiphertextDirectoryDeletion: Sendable {
	/// The provider that holds the ciphertext directories, below any shortening decorator, so that a listing shows every item, also one whose shortened name can't be restored.
	let provider: CloudProvider
	let stop: CiphertextDirectoryDeletionStop
	let directoryPath: @Sendable (_ dirId: Data) throws -> CloudPath
	/// Returns the dir IDs that a physical item of a directory refers to, none for an item that isn't a subdirectory.
	let subdirectoryIds: @Sendable (CloudItemMetadata) async throws -> [Data]

	init(provider: CloudProvider, stop: CiphertextDirectoryDeletionStop = CiphertextDirectoryDeletionStop(), directoryPath: @escaping @Sendable (_ dirId: Data) throws -> CloudPath, subdirectoryIds: @escaping @Sendable (CloudItemMetadata) async throws -> [Data]) {
		self.provider = provider
		self.stop = stop
		self.directoryPath = directoryPath
		self.subdirectoryIds = subdirectoryIds
	}

	/**
	 Deletes the ciphertext directory of a dir ID and those of its subdirectories. Must run inside `withoutCancellation`, because stopping halfway leaves folders whose directory is missing.

	 - Parameter containingDirIds: The dir IDs of the vault root and of the ancestors of the folder that the dir ID belongs to.
	 - Throws: The highest-ranked failure that was observed in the subdirectories and in a directory's own listing and delete, the first one on a tie. A skipped item or page counts as the stopping error. `CloudProviderError.deletionIncomplete` ranks highest, if the cloud refused to delete something, then `CloudProviderError.itemNotFound`, if a directory exists but can't be listed. `CloudProviderError.itemTypeMismatch` of a subdirectory or of a directory's own delete counts as the latter.
	 */
	func deleteDirectory(of dirId: Data, containingDirIds: Set<Data>) async throws {
		try await deleteDirectory(at: directoryPath(dirId), visitedDirIds: containingDirIds.union([dirId]))
	}

	private func deleteDirectory(at dirPath: CloudPath, visitedDirIds: Set<Data>) async throws {
		var failure: Error?
		var pageToken: String?
		repeat {
			if let stopError = stop.error {
				throw prevailingFailure(failure, stopError)
			}
			let itemList: CloudItemList
			do {
				itemList = try await provider.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
			} catch CloudProviderError.itemNotFound where pageToken == nil {
				// Counts as deleted only if the directory is gone, because the parent then deletes the reference, which would orphan a directory that still exists.
				if try await stop.observing({ try await provider.checkForItemExistence(at: dirPath) }) {
					throw CloudProviderError.itemNotFound
				}
				return
			} catch CloudProviderError.itemTypeMismatch where pageToken == nil {
				try await stop.observing { try await deleteStrayFile(at: dirPath) }
				return
			} catch where !(error is CancellationError) {
				stop.observe(error)
				throw prevailingFailure(failure, error)
			}
			let itemFailures = try await mapConcurrently(itemList.items, limit: vaultItemConcurrencyLimit) { item in
				try await deleteSubdirectories(of: item, visitedDirIds: visitedDirIds)
			}
			for case let itemFailure? in itemFailures {
				failure = prevailingFailure(failure, itemFailure)
			}
			pageToken = itemList.nextPageToken
		} while pageToken != nil
		if let failure {
			throw failure
		}
		try await stop.observing {
			do {
				try await provider.deleteFolder(at: dirPath)
			} catch CloudProviderError.itemNotFound {
				// The directory disappeared after it was listed, or the provider listed a missing folder as empty. Either way it counts as deleted.
			} catch CloudProviderError.itemTypeMismatch {
				// Another client put a file there. It still exists, and a raw `itemTypeMismatch` would read as the deleted folder being no folder.
				throw CloudProviderError.itemNotFound
			}
		}
	}

	/// Deletes the directories that an item refers to, unless the delete was stopped before. Returns the item's failure instead of throwing it, because `mapConcurrently` would cancel the other items.
	private func deleteSubdirectories(of item: CloudItemMetadata, visitedDirIds: Set<Data>) async throws -> Error? {
		if let stopError = stop.error {
			return stopError
		}
		if item.isAlias {
			return nil
		}
		do {
			for dirId in try await subdirectoryIds(item) {
				guard !visitedDirIds.contains(dirId) else {
					throw VaultFormatError.invalidDirectoryReference
				}
				try await deleteDirectory(at: directoryPath(dirId), visitedDirIds: visitedDirIds.union([dirId]))
			}
			return nil
		} catch CloudProviderError.itemTypeMismatch {
			// The caller of the folder delete would take a descendant's `itemTypeMismatch` for the deleted folder itself being no folder.
			return CloudProviderError.itemNotFound
		} catch where !(error is CancellationError) {
			stop.observe(error)
			return error
		}
	}

	/**
	 Deletes the file at the path of a ciphertext directory, which nothing but a broken sync or another app puts there.

	 The metadata read and the delete aren't atomic. A provider whose `deleteFile` also deletes a folder (WebDAV and Dropbox, and the local file system when the other writer doesn't use file coordination) would therefore delete a folder that another writer creates at the path in between, which no Cryptomator client does.

	 - Throws: `CloudProviderError.itemNotFound` if the path holds something other than a file, also when the provider refuses the delete because a folder appeared there. It also throws it if the path still exists after the delete, e.g., on S3, where a prefix can hold objects beside an object of the same name.
	 */
	private func deleteStrayFile(at dirPath: CloudPath) async throws {
		let metadata: CloudItemMetadata
		do {
			metadata = try await provider.fetchItemMetadata(at: dirPath)
		} catch CloudProviderError.itemNotFound {
			return
		}
		guard metadata.itemType == .file else {
			throw CloudProviderError.itemNotFound
		}
		do {
			try await provider.deleteFile(at: dirPath)
		} catch CloudProviderError.itemNotFound {
			// Another client deleted it.
		} catch CloudProviderError.itemTypeMismatch {
			// Another client put a folder there.
			throw CloudProviderError.itemNotFound
		}
		if try await provider.checkForItemExistence(at: dirPath) {
			throw CloudProviderError.itemNotFound
		}
	}
}

/// Returns the failure that `CiphertextDirectoryDeletion` throws of the two, keeping `recorded` on a tie. A refusal ranks highest, then a directory that exists but can't be listed, then any other failure.
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

/// Whether the delete takes the failure for one of the account or the connection rather than of an item.
private func isStoppingFailure(_ failure: Error) -> Bool {
	switch failure {
	case CloudProviderError.unauthorized, CloudProviderError.noInternetConnection:
		return true
	case let DropboxError.apiError(statusCode: 401, summary):
		return DropboxErrorResponse.isUserSuspended(summary: summary)
	default:
		return false
	}
}
