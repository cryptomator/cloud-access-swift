//
//  CiphertextDirectoryDeletionTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct CiphertextDirectoryDeletionTests {
		@Test(arguments: [CloudProviderError.unauthorized, .noInternetConnection])
		func stoppingFailureAdmitsNoFurtherItem(failure: CloudProviderError) async throws {
			try await expectNoFurtherItemAdmitted(after: failure)
		}

		@Test
		func suspendedDropboxAccountAdmitsNoFurtherItem() async throws {
			try await expectNoFurtherItemAdmitted(after: DropboxError.apiError(statusCode: 401, summary: "user_suspended/.."))
		}

		@Test
		func stoppingFailureFetchesNoFurtherPage() async throws {
			try await expectNoFurtherPageFetched(after: CloudProviderError.unauthorized)
		}

		@Test
		func suspendedDropboxAccountFetchesNoFurtherPage() async throws {
			try await expectNoFurtherPageFetched(after: DropboxError.apiError(statusCode: 401, summary: "user_suspended/.."))
		}

		/// The items admitted before the stop finish resolving their dir IDs but walk no subdirectory, and the items after them never start.
		private func expectNoFurtherItemAdmitted(after failure: some Error & Equatable) async throws {
			let itemNames = (0 ..< vaultItemConcurrencyLimit + 2).map { String(format: "item%02d", $0) }
			let provider = CloudProviderMock(folders: ["dirs", "dirs/top"], files: Dictionary(uniqueKeysWithValues: itemNames.map { ("dirs/top/\($0)", Data()) }))
			let listedFolders = OSAllocatedUnfairLock(initialState: [String]())
			provider.listingHook = { cloudPath, _ in
				listedFolders.withLock { $0.append(cloudPath.path) }
			}
			let startedItems = OSAllocatedUnfairLock(initialState: [String]())
			let resolvedItems = OSAllocatedUnfairLock(initialState: [String]())
			let otherItemsStarted = TestSignal("other items within the limit started", expectedCount: vaultItemConcurrencyLimit - 1)
			let recorded = TestSignal("stopping failure recorded")
			let gate = Gate()
			let stop = CiphertextDirectoryDeletionStop(events: .init(didRecord: { _ in recorded.fulfill() }))
			let deletion = Task {
				try await deleteDirectory(of: provider, stop: stop) { item in
					startedItems.withLock { $0.append(item.name) }
					guard item.name != itemNames[0] else {
						await otherItemsStarted.wait()
						throw failure
					}
					otherItemsStarted.fulfill()
					await gate.wait()
					resolvedItems.withLock { $0.append(item.name) }
					return [Data(item.name.utf8)]
				}
			}
			await recorded.wait()
			gate.open()
			await #expect(throws: failure) { try await cancellingValue(of: deletion) }
			#expect(startedItems.withLock { $0 }.sorted() == Array(itemNames.prefix(vaultItemConcurrencyLimit)))
			#expect(resolvedItems.withLock { $0 }.sorted() == Array(itemNames[1 ..< vaultItemConcurrencyLimit]))
			#expect(listedFolders.withLock { $0 } == ["dirs/top"])
			#expect(provider.deleted == [])
		}

		private func expectNoFurtherPageFetched(after failure: some Error & Equatable) async throws {
			let provider = CloudProviderMock(folders: ["dirs", "dirs/top"], files: ["dirs/top/a": Data(), "dirs/top/b": Data()], maxPageSize: 1)
			let listedPages = OSAllocatedUnfairLock(initialState: [String]())
			provider.listingHook = { cloudPath, pageToken in
				listedPages.withLock { $0.append("\(cloudPath.path)#\(pageToken ?? "")") }
			}
			await #expect(throws: failure) {
				try await deleteDirectory(of: provider, stop: CiphertextDirectoryDeletionStop()) { _ in
					throw failure
				}
			}
			#expect(listedPages.withLock { $0 } == ["dirs/top#"])
		}

		/// The refusal of `dirs/y1` outranks the `unauthorized` of the second page of `dirs/x` in the failure of `dirs/x`, which still keeps `dirs/top` from fetching its second page.
		@Test
		func stoppingFailureBehindRefusalFetchesNoFurtherPage() async throws {
			let provider = CloudProviderMock(folders: ["dirs", "dirs/top", "dirs/x", "dirs/y1"], files: ["dirs/top/a": Data(), "dirs/top/b": Data(), "dirs/x/p": Data(), "dirs/x/q": Data()], maxPageSize: 1)
			provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["dirs/y1"])
			let listedPages = OSAllocatedUnfairLock(initialState: [String]())
			provider.listingHook = { cloudPath, pageToken in
				listedPages.withLock { $0.append("\(cloudPath.path)#\(pageToken ?? "")") }
				if cloudPath.path == "dirs/x", pageToken != nil {
					throw CloudProviderError.unauthorized
				}
			}
			let dirIds = ["a": "x", "p": "y1"]
			await #expect(throws: CloudProviderError.deletionIncomplete) {
				try await deleteDirectory(of: provider, stop: CiphertextDirectoryDeletionStop()) { item in
					return dirIds[item.name].map { [Data($0.utf8)] } ?? []
				}
			}
			#expect(listedPages.withLock { $0 } == ["dirs/top#", "dirs/x#", "dirs/y1#", "dirs/x#1"])
		}

		/// An alias's target need not lie inside the deleted directory, so its dir IDs aren't read.
		@Test
		func aliasIsNotFollowed() async throws {
			let provider = CloudProviderMock(folders: ["dirs", "dirs/top", "dirs/top/alias", "dirs/top/sub", "dirs/x"], files: [:], aliases: ["dirs/top/alias"])
			let resolvedItems = OSAllocatedUnfairLock(initialState: [String]())
			try await deleteDirectory(of: provider, stop: CiphertextDirectoryDeletionStop()) { item in
				resolvedItems.withLock { $0.append(item.name) }
				return item.name == "sub" ? [Data("x".utf8)] : []
			}
			#expect(resolvedItems.withLock { $0 } == ["sub"])
			#expect(provider.deleted == ["dirs/x", "dirs/top"])
		}

		// MARK: - Precedence

		@Test
		func refusalOutranksOtherFailureOfSamePage() async throws {
			let provider = makeProvider(directories: ["x", "y", "z"], files: ["dirs/top/a", "dirs/top/b", "dirs/top/c"])
			provider.afterMutationHook = { call, cloudPath in
				guard call == "deleteFolder" else {
					return
				}
				switch cloudPath.path {
				case "dirs/x": throw CloudProviderError.deletionIncomplete
				case "dirs/y": throw CloudProviderError.quotaInsufficient
				default: break
				}
			}
			await #expect(throws: CloudProviderError.deletionIncomplete) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x", "b": "y", "c": "z"]))
			}
			#expect(provider.deleted.sorted() == ["dirs/x", "dirs/y", "dirs/z"])
		}

		@Test
		func refusalOutranksLaterPageListingFailure() async throws {
			let provider = makeProvider(directories: ["x"], files: ["dirs/top/a", "dirs/top/b"], maxPageSize: 1)
			provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["dirs/x"])
			provider.listingHook = failingListing(of: "dirs/top", with: CloudProviderError.unauthorized, laterPagesOnly: true)
			await #expect(throws: CloudProviderError.deletionIncomplete) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			}
			#expect(provider.deleted == ["dirs/x"])
		}

		@Test
		func unlistableSubdirectoryOutranksLaterPageListingFailure() async throws {
			let provider = makeProvider(directories: ["x"], files: ["dirs/top/a", "dirs/top/b"], maxPageSize: 1)
			provider.listingHook = { cloudPath, pageToken in
				switch (cloudPath.path, pageToken) {
				case ("dirs/x", _): throw CloudProviderError.itemNotFound
				case ("dirs/top", .some): throw CloudProviderError.unauthorized
				default: break
				}
			}
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			}
			#expect(provider.deleted == [])
		}

		/// The failure of `x` on the first page doesn't stop the delete, and the unlistable `y` on the second page outranks it.
		@Test
		func unlistableSubdirectoryOnLaterPageOutranksEarlierFailure() async throws {
			let provider = makeProvider(directories: ["x", "y"], files: ["dirs/top/a", "dirs/top/b"], maxPageSize: 1)
			provider.listingHook = { cloudPath, _ in
				switch cloudPath.path {
				case "dirs/x": throw CloudProviderError.quotaInsufficient
				case "dirs/y": throw CloudProviderError.itemNotFound
				default: break
				}
			}
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x", "b": "y"]))
			}
			#expect(provider.deleted == [])
		}

		@Test
		func laterPageListingItemNotFoundOutranksEarlierFailure() async throws {
			let provider = makeProvider(directories: ["x"], files: ["dirs/top/a", "dirs/top/b"], maxPageSize: 1)
			provider.listingHook = { cloudPath, pageToken in
				switch (cloudPath.path, pageToken) {
				case ("dirs/x", _): throw CloudProviderError.quotaInsufficient
				case ("dirs/top", .some): throw CloudProviderError.itemNotFound
				default: break
				}
			}
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			}
			#expect(provider.deleted == [])
		}

		/// Of two failures of the same rank, the first item's wins, on one page as on two.
		@Test(arguments: [1, Int.max])
		func firstFailureWinsOnTie(maxPageSize: Int) async throws {
			let provider = makeProvider(directories: ["x", "y"], files: ["dirs/top/a", "dirs/top/b"], maxPageSize: maxPageSize)
			provider.listingHook = { cloudPath, _ in
				switch cloudPath.path {
				case "dirs/x": throw CloudProviderError.quotaInsufficient
				case "dirs/y": throw CloudProviderError.pageTokenInvalid
				default: break
				}
			}
			await #expect(throws: CloudProviderError.quotaInsufficient) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x", "b": "y"]))
			}
		}

		// MARK: - Kept Parents

		@Test(arguments: [false, true])
		func failedSubdirectoryKeepsParentBesideDeletedSibling(failsResolving: Bool) async throws {
			let provider = makeProvider(directories: ["x", "y"], files: ["dirs/top/a", "dirs/top/b"])
			provider.listingHook = failsResolving ? nil : failingListing(of: "dirs/x", with: CloudProviderError.quotaInsufficient)
			let resolve = subdirectories(["a": "x", "b": "y"])
			await #expect(throws: CloudProviderError.quotaInsufficient) {
				try await deleteDirectory(of: provider) { item in
					if failsResolving, item.name == "a" {
						throw CloudProviderError.quotaInsufficient
					}
					return try await resolve(item)
				}
			}
			#expect(provider.deleted == ["dirs/y"])
		}

		/// The refusal of `z` keeps its ancestors although its parent's sibling `y` is deleted.
		@Test
		func refusedNestedSubdirectoryKeepsAncestors() async throws {
			let provider = makeProvider(directories: ["x", "y", "z"], files: ["dirs/top/a", "dirs/top/b", "dirs/x/c"])
			provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: ["dirs/z"])
			await #expect(throws: CloudProviderError.deletionIncomplete) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x", "b": "y", "c": "z"]))
			}
			#expect(provider.deleted.sorted() == ["dirs/y", "dirs/z"])
		}

		// MARK: - Missing Directories

		/// The mock lists a missing folder as empty, so the hook fails its listing as a real provider does.
		@Test
		func missingSubdirectoryCountsAsDeleted() async throws {
			let provider = makeProvider(directories: [], files: ["dirs/top/a"])
			provider.listingHook = failingListing(of: "dirs/x", with: CloudProviderError.itemNotFound)
			try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			#expect(provider.deleted == ["dirs/top"])
		}

		/// A listing can throw `itemNotFound` while the directory still exists, so the delete counts it as deleted only if the directory is gone.
		@Test
		func existingSubdirectoryWhoseListingThrowsItemNotFoundKeepsParent() async throws {
			let provider = makeProvider(directories: ["x"], files: ["dirs/top/a"])
			provider.listingHook = failingListing(of: "dirs/x", with: CloudProviderError.itemNotFound)
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			}
			#expect(provider.deleted == [])
		}

		/// The directory disappeared after it was listed.
		@Test
		func finalDeleteOfMissingDirectoryCountsAsDeleted() async throws {
			let provider = makeProvider(directories: ["x"], files: ["dirs/top/a"])
			provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.itemNotFound, at: ["dirs/x"])
			try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			#expect(provider.deleted == ["dirs/x", "dirs/top"])
		}

		// MARK: - Item Type Mismatches

		/// The caller of the folder delete would take a descendant's `itemTypeMismatch` for the deleted folder itself being no folder.
		@Test
		func resolvingItemTypeMismatchThrowsItemNotFound() async throws {
			let provider = makeProvider(directories: [], files: ["dirs/top/a"])
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await deleteDirectory(of: provider) { _ in
					throw CloudProviderError.itemTypeMismatch
				}
			}
			#expect(provider.deleted == [])
		}

		/// Only a first page tells a file at the path from a directory, so a later page's `itemTypeMismatch` deletes nothing. A subdirectory's is thrown as `itemNotFound`, the directory's own unchanged.
		@Test(arguments: [false, true])
		func laterPageItemTypeMismatchKeepsDirectory(inSubdirectory: Bool) async throws {
			let provider = makeProvider(directories: ["x"], files: ["dirs/top/a", "dirs/top/b", "dirs/x/p", "dirs/x/q"], maxPageSize: 1)
			provider.listingHook = failingListing(of: inSubdirectory ? "dirs/x" : "dirs/top", with: CloudProviderError.itemTypeMismatch, laterPagesOnly: true)
			await #expect(throws: inSubdirectory ? CloudProviderError.itemNotFound : .itemTypeMismatch) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(inSubdirectory ? ["a": "x"] : [:]))
			}
			#expect(!provider.calls.contains("fetchItemMetadata"))
			#expect(provider.deleted == [])
		}

		// MARK: - Stray Files

		/// A file at the path of a directory is deleted, and then its parent, as Cryptomator Desktop does.
		@Test
		func strayFileAtDirectoryPathIsDeleted() async throws {
			let provider = makeProvider(directories: [], files: ["dirs/top/a", "dirs/x"])
			provider.metadataOverride = CloudProviderMock.reading([.file, nil], at: "dirs/x")
			try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			#expect(provider.deleted == ["dirs/x", "dirs/top"])
		}

		@Test(arguments: [CloudItemType.folder, .symlink, .unknown])
		func otherItemAtDirectoryPathKeepsParent(itemType: CloudItemType) async throws {
			let provider = makeProvider(directories: [], files: ["dirs/top/a", "dirs/x"])
			provider.metadataOverride = CloudProviderMock.reading([itemType], at: "dirs/x")
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			}
			#expect(!provider.calls.contains("deleteFile"))
			#expect(provider.deleted == [])
		}

		/// On S3, a prefix holding objects can appear beside an object of the same name.
		@Test
		func directoryPathRemainingAfterFileDeleteKeepsParent() async throws {
			let provider = makeProvider(directories: [], files: ["dirs/top/a", "dirs/x"])
			provider.metadataOverride = CloudProviderMock.reading([.file, .folder], at: "dirs/x")
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			}
			#expect(provider.calls == ["fetchItemList", "fetchItemList", "fetchItemMetadata", "deleteFile", "fetchItemMetadata"])
			#expect(provider.deleted == ["dirs/x"])
		}

		/// The item at the path disappeared between its listing and its metadata read.
		@Test
		func directoryPathGoneAfterListingCountsAsDeleted() async throws {
			let provider = makeProvider(directories: [], files: ["dirs/top/a", "dirs/x"])
			provider.metadataOverride = CloudProviderMock.reading([nil], at: "dirs/x")
			try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			#expect(provider.calls.contains("fetchItemMetadata"))
			#expect(provider.deleted == ["dirs/top"])
		}

		@Test
		func refusedStrayFileDeleteKeepsParent() async throws {
			let provider = makeProvider(directories: [], files: ["dirs/top/a", "dirs/x"])
			provider.metadataOverride = CloudProviderMock.reading([.file], at: "dirs/x")
			provider.afterMutationHook = CloudProviderMock.failing("deleteFile", with: CloudProviderError.deletionIncomplete)
			await #expect(throws: CloudProviderError.deletionIncomplete) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			}
			#expect(provider.deleted == ["dirs/x"])
		}

		/// A folder that another writer created at the path after the metadata read makes the provider refuse the file delete. At the deleted folder's own directory, a raw `itemTypeMismatch` would reach the caller, which would take it for the folder being no folder.
		@Test
		func strayFileReplacedByFolderAtTopLevelThrowsItemNotFound() async throws {
			let provider = makeProvider(directories: [])
			provider.listingHook = failingListing(of: "dirs/top", with: CloudProviderError.itemTypeMismatch)
			provider.metadataOverride = CloudProviderMock.reading([.file, nil], at: "dirs/top")
			provider.afterMutationHook = CloudProviderMock.failing("deleteFile", with: CloudProviderError.itemTypeMismatch)
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories([:]))
			}
			#expect(provider.calls.last == "deleteFile")
		}

		/// A file that another writer put at the path after the listing makes the provider refuse the directory's delete, which the caller would take for the deleted folder being no folder.
		@Test
		func directoryReplacedByFileBeforeItsDeleteThrowsItemNotFound() async throws {
			let provider = makeProvider(directories: [])
			provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.itemTypeMismatch, at: ["dirs/top"])
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories([:]))
			}
			#expect(provider.calls.last == "deleteFolder")
		}

		@Test
		func failedMetadataReadAtDirectoryPathKeepsParent() async throws {
			let provider = makeProvider(directories: [], files: ["dirs/top/a", "dirs/x"])
			provider.metadataHook = { _ in
				throw CloudProviderError.unauthorized
			}
			await #expect(throws: CloudProviderError.unauthorized) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x"]))
			}
			#expect(provider.deleted == [])
		}

		// MARK: - Directory References

		@Test
		func dirIdOfDirectoryItselfThrowsInvalidDirectoryReference() async throws {
			let provider = makeProvider(directories: [], files: ["dirs/top/a"])
			let listedFolders = OSAllocatedUnfairLock(initialState: [String]())
			provider.listingHook = CloudProviderMock.listingEachFolderOnce(recordingInto: listedFolders)
			await #expect(throws: VaultFormatError.invalidDirectoryReference) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "top"]))
			}
			#expect(listedFolders.withLock { $0 } == ["dirs/top"])
			#expect(provider.deleted == [])
		}

		@Test
		func containingDirIdThrowsInvalidDirectoryReference() async throws {
			let provider = makeProvider(directories: ["root"], files: ["dirs/top/a"])
			await #expect(throws: VaultFormatError.invalidDirectoryReference) {
				try await deleteDirectory(of: provider, containingDirIds: [Data("root".utf8)], subdirectoryIds: subdirectories(["a": "root"]))
			}
			#expect(provider.deleted == [])
		}

		/// `b` inside `x` refers to `top`, which contains both.
		@Test
		func dirIdCycleBelowDirectoryThrowsInvalidDirectoryReference() async throws {
			let provider = makeProvider(directories: ["x"], files: ["dirs/top/a", "dirs/x/b"])
			let listedFolders = OSAllocatedUnfairLock(initialState: [String]())
			provider.listingHook = CloudProviderMock.listingEachFolderOnce(recordingInto: listedFolders)
			await #expect(throws: VaultFormatError.invalidDirectoryReference) {
				try await deleteDirectory(of: provider, subdirectoryIds: subdirectories(["a": "x", "b": "top"]))
			}
			#expect(listedFolders.withLock { $0 } == ["dirs/top", "dirs/x"])
			#expect(provider.deleted == [])
		}

		// MARK: - Concurrency

		@Test
		func resolvesAtMostLimitItemsOfALevelAtOnce() async throws {
			let itemNames = (0 ..< vaultItemConcurrencyLimit + 2).map { String(format: "item%02d", $0) }
			let provider = makeProvider(directories: [], files: itemNames.map { "dirs/top/\($0)" })
			let runningCount = OSAllocatedUnfairLock(initialState: 0)
			let gate = Gate()
			let limitStarted = TestSignal("limit of items started", expectedCount: vaultItemConcurrencyLimit, allowsOverFulfillment: true)
			let limitExceeded = TestSignal("more items than the limit ran at once", allowsOverFulfillment: true)
			let deletion = Task {
				try await deleteDirectory(of: provider) { _ in
					let running = runningCount.withLock { count in
						count += 1
						return count
					}
					if running > vaultItemConcurrencyLimit {
						limitExceeded.fulfill()
					} else {
						limitStarted.fulfill()
					}
					await gate.wait()
					runningCount.withLock { $0 -= 1 }
					return []
				}
			}
			await limitStarted.wait()
			await limitExceeded.expectNoFulfillment(within: .seconds(0.2))
			gate.open()
			try await cancellingValue(of: deletion)
			#expect(provider.deleted == ["dirs/top"])
		}
	}
}

/// Deletes the directory `dirs/top`, whose subdirectories lie at `dirs/<dir ID>`.
private func deleteDirectory(of provider: CloudProvider, stop: CiphertextDirectoryDeletionStop = CiphertextDirectoryDeletionStop(), containingDirIds: Set<Data> = [], subdirectoryIds: @escaping @Sendable (CloudItemMetadata) async throws -> [Data]) async throws {
	let deletion = CiphertextDirectoryDeletion(provider: provider, stop: stop, directoryPath: { CloudPath("dirs/\(String(bytes: $0, encoding: .utf8)!)") }, subdirectoryIds: subdirectoryIds)
	try await deletion.deleteDirectory(of: Data("top".utf8), containingDirIds: containingDirIds)
}

/// Resolves each listed item of the given name to the given dir ID, and every other item to none.
private func subdirectories(_ dirIds: [String: String]) -> @Sendable (CloudItemMetadata) async throws -> [Data] {
	return { item in
		dirIds[item.name].map { [Data($0.utf8)] } ?? []
	}
}

/// Returns a provider that holds the directories `dirs/top` and `dirs/<name>` for each given name and the given files.
private func makeProvider(directories: [String], files: [String] = [], maxPageSize: Int = .max) -> CloudProviderMock {
	return CloudProviderMock(folders: Set(["dirs", "dirs/top"] + directories.map { "dirs/\($0)" }), files: Dictionary(uniqueKeysWithValues: files.map { ($0, Data()) }), maxPageSize: maxPageSize)
}

/// Returns a `listingHook` that fails the listing of the given folder with the given error, only on later pages if `laterPagesOnly`.
private func failingListing(of path: String, with error: Error, laterPagesOnly: Bool = false) -> @Sendable (CloudPath, String?) throws -> Void {
	return { cloudPath, pageToken in
		if cloudPath.path == path, !laterPagesOnly || pageToken != nil {
			throw error
		}
	}
}
