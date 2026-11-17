//
//  CloudProvider+ConvenienceTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 26.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct CloudProvider_ConvenienceTests {
		@Test
		func testFetchItemListExhaustively() async throws {
			let provider = ConvenienceCloudProviderMock()
			let cloudItemList = try await provider.fetchItemListExhaustively(forFolderAt: CloudPath("/"))
			#expect(cloudItemList.items.count == 6)
			#expect(cloudItemList.items.contains(where: { $0.name == "a" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "b" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "c" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "d" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "e" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "f" }))
		}

		@Test
		func createFolderIfMissingFulfillsForExistingItem() async throws {
			let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
			let provider = ConvenienceCloudProviderMock()
			try await provider.createFolderIfMissing(at: existingItemPath)
		}

		@Test
		func createFolderIfMissingFulfillsForMissingItem() async throws {
			let nonExistentItemPath = CloudPath("/nonExistentFolder")
			let provider = ConvenienceCloudProviderMock()
			try await provider.createFolderIfMissing(at: nonExistentItemPath)
		}

		@Test
		func createFolderIfMissingRejectsWithErrorOtherThanItemNotFound() async throws {
			let itemPath = CloudPath("/AAAAA/BBBB")
			let provider = ConvenienceCloudProviderMock()
			await #expect(throws: CloudProviderError.noInternetConnection) { try await provider.createFolderIfMissing(at: itemPath) }
		}

		@Test
		func deleteFolderIfExistingFulfillsForMissingItem() async throws {
			let nonExistentItemPath = CloudPath("/nonExistentFolder")
			let provider = ConvenienceCloudProviderMock()
			try await provider.deleteFolderIfExisting(at: nonExistentItemPath)
		}

		@Test
		func deleteFolderIfExistingFulfillsForExistingItem() async throws {
			let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
			let provider = ConvenienceCloudProviderMock()
			try await provider.deleteFolderIfExisting(at: existingItemPath)
		}

		@Test
		func deleteFolderIfExistingRejectsForUnlistableExistingItem() async throws {
			let unlistableItemPath = CloudPath("/unlistableFolder")
			let provider = ConvenienceCloudProviderMock()
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.deleteFolderIfExisting(at: unlistableItemPath) }
		}

		@Test
		func deleteFolderIfExistingRejectsWithErrorOtherThanItemNotFound() async throws {
			let itemPath = CloudPath("/AAAAA/BBBB")
			let provider = ConvenienceCloudProviderMock()
			await #expect(throws: CloudProviderError.noInternetConnection) { try await provider.deleteFolderIfExisting(at: itemPath) }
		}

		@Test
		func checkForItemExistenceFulfillsForExistingItem() async throws {
			let provider = ConvenienceCloudProviderMock()
			let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
			let itemExists = try await provider.checkForItemExistence(at: existingItemPath)
			#expect(itemExists)
		}

		@Test
		func checkForItemExistenceFulfillsForMissingItem() async throws {
			let provider = ConvenienceCloudProviderMock()
			let nonExistentItemPath = CloudPath("/nonExistentFile")
			let itemExists = try await provider.checkForItemExistence(at: nonExistentItemPath)
			#expect(!itemExists)
		}

		@Test
		func checkForItemExistenceRejectsWithErrorOtherThanItemNotFound() async throws {
			let provider = ConvenienceCloudProviderMock()
			let itemPath = CloudPath("/AAAAA/BBBB")
			await #expect(throws: CloudProviderError.noInternetConnection) { try await provider.checkForItemExistence(at: itemPath) }
		}
	}
}

private final class ConvenienceCloudProviderMock: CloudProvider {
	let pages = [
		"0": [
			CloudItemMetadata(name: "a", cloudPath: CloudPath("/a"), itemType: .file, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "b", cloudPath: CloudPath("/b"), itemType: .file, lastModifiedDate: nil, size: nil)
		],
		"1": [
			CloudItemMetadata(name: "c", cloudPath: CloudPath("/c"), itemType: .file, lastModifiedDate: nil, size: nil)
		],
		"2": [
			CloudItemMetadata(name: "d", cloudPath: CloudPath("/d"), itemType: .file, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "e", cloudPath: CloudPath("/e"), itemType: .file, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "f", cloudPath: CloudPath("/f"), itemType: .file, lastModifiedDate: nil, size: nil)
		]
	]

	@concurrent
	func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		let nonExistentItemPaths = [CloudPath("/nonExistentFile"), CloudPath("/nonExistentFolder")]
		let existingItemPaths = [CloudPath("/thisFolderExistsInTheCloud"), CloudPath("/unlistableFolder")]
		switch cloudPath {
		case _ where nonExistentItemPaths.contains(cloudPath):
			throw CloudProviderError.itemNotFound
		case _ where existingItemPaths.contains(cloudPath):
			return CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .folder, lastModifiedDate: nil, size: nil)
		default:
			throw CloudProviderError.noInternetConnection
		}
	}

	@concurrent
	func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		switch pageToken {
		case nil:
			return CloudItemList(items: pages["0"]!, nextPageToken: "1")
		case "1":
			return CloudItemList(items: pages["1"]!, nextPageToken: "2")
		case "2":
			return CloudItemList(items: pages["2"]!, nextPageToken: nil)
		default:
			throw CloudProviderError.noInternetConnection
		}
	}

	@concurrent
	func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		throw CloudProviderError.noInternetConnection
	}

	@concurrent
	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		throw CloudProviderError.noInternetConnection
	}

	@concurrent
	func createFolder(at cloudPath: CloudPath) async throws {
		let nonExistentItemPath = CloudPath("/nonExistentFolder")
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		switch cloudPath {
		case nonExistentItemPath:
			return
		case existingItemPath:
			throw CloudProviderError.itemAlreadyExists
		default:
			throw CloudProviderError.noInternetConnection
		}
	}

	@concurrent
	func deleteFile(at cloudPath: CloudPath) async throws {
		try deleteItem(at: cloudPath)
	}

	@concurrent
	func deleteFolder(at cloudPath: CloudPath) async throws {
		try deleteItem(at: cloudPath)
	}

	/// `/unlistableFolder` exists, but deleting it throws `itemNotFound`, as a vault provider does for a folder it can't list.
	private func deleteItem(at cloudPath: CloudPath) throws {
		let notFoundItemPaths = [CloudPath("/nonExistentFolder"), CloudPath("/unlistableFolder")]
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		switch cloudPath {
		case _ where notFoundItemPaths.contains(cloudPath):
			throw CloudProviderError.itemNotFound
		case existingItemPath:
			return
		default:
			throw CloudProviderError.noInternetConnection
		}
	}

	@concurrent
	func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		throw CloudProviderError.noInternetConnection
	}

	@concurrent
	func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		throw CloudProviderError.noInternetConnection
	}
}
