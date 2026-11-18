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
		/// The items admitted before the stop finish resolving their dir IDs but walk no subdirectory, and the items after them never start.
		@Test(arguments: [CloudProviderError.unauthorized, .noInternetConnection])
		func stoppingFailureAdmitsNoFurtherItem(failure: CloudProviderError) async throws {
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

		@Test
		func stoppingFailureFetchesNoFurtherPage() async throws {
			let provider = CloudProviderMock(folders: ["dirs", "dirs/top"], files: ["dirs/top/a": Data(), "dirs/top/b": Data()], maxPageSize: 1)
			let listedPages = OSAllocatedUnfairLock(initialState: [String]())
			provider.listingHook = { cloudPath, pageToken in
				listedPages.withLock { $0.append("\(cloudPath.path)#\(pageToken ?? "")") }
			}
			await #expect(throws: CloudProviderError.unauthorized) {
				try await deleteDirectory(of: provider, stop: CiphertextDirectoryDeletionStop()) { _ in
					throw CloudProviderError.unauthorized
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
	}
}

/// Deletes the directory `dirs/top`, whose subdirectories lie at `dirs/<dir ID>`.
private func deleteDirectory(of provider: CloudProvider, stop: CiphertextDirectoryDeletionStop, subdirectoryIds: @escaping @Sendable (CloudItemMetadata) async throws -> [Data]) async throws {
	let deletion = CiphertextDirectoryDeletion(provider: provider, stop: stop, directoryPath: { CloudPath("dirs/\(String(bytes: $0, encoding: .utf8)!)") }, subdirectoryIds: subdirectoryIds)
	try await deletion.deleteDirectory(of: Data("top".utf8), containingDirIds: [])
}
