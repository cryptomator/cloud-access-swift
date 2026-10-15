//
//  CloudProvider+ConvenienceTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 26.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import XCTest

class CloudProvider_ConvenienceTests: XCTestCase {
	func testFetchItemListExhaustively() async throws {
		let provider = ConvenienceCloudProviderMock()
		let cloudItemList = try await provider.fetchItemListExhaustively(forFolderAt: CloudPath("/"))
		XCTAssertEqual(6, cloudItemList.items.count)
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "a" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "b" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "c" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "d" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "e" }))
		XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "f" }))
	}

	func testCreateFolderIfMissingFulfillsForExistingItem() async throws {
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		let provider = ConvenienceCloudProviderMock()
		try await provider.createFolderIfMissing(at: existingItemPath)
	}

	func testCreateFolderIfMissingFulfillsForMissingItem() async throws {
		let nonExistentItemPath = CloudPath("/nonExistentFolder")
		let provider = ConvenienceCloudProviderMock()
		try await provider.createFolderIfMissing(at: nonExistentItemPath)
	}

	func testCreateFolderIfMissingRejectsWithErrorOtherThanItemNotFound() async throws {
		let itemPath = CloudPath("/AAAAA/BBBB")
		let provider = ConvenienceCloudProviderMock()
		await XCTAssertThrowsErrorAsync(try await provider.createFolderIfMissing(at: itemPath)) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
		}
	}

	func testDeleteFolderIfExistingFulfillsForMissingItem() async throws {
		let nonExistentItemPath = CloudPath("/nonExistentFolder")
		let provider = ConvenienceCloudProviderMock()
		try await provider.deleteFolderIfExisting(at: nonExistentItemPath)
	}

	func testDeleteFolderIfExistingFulfillsForExistingItem() async throws {
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		let provider = ConvenienceCloudProviderMock()
		try await provider.deleteFolderIfExisting(at: existingItemPath)
	}

	func testDeleteFolderIfExistingRejectsWithErrorOtherThanItemNotFound() async throws {
		let itemPath = CloudPath("/AAAAA/BBBB")
		let provider = ConvenienceCloudProviderMock()
		await XCTAssertThrowsErrorAsync(try await provider.deleteFolderIfExisting(at: itemPath)) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
		}
	}

	func testCheckForItemExistenceFulfillsForExistingItem() async throws {
		let provider = ConvenienceCloudProviderMock()
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		let itemExists = try await provider.checkForItemExistence(at: existingItemPath)
		XCTAssertTrue(itemExists)
	}

	func testCheckForItemExistenceFulfillsForMissingItem() async throws {
		let provider = ConvenienceCloudProviderMock()
		let nonExistentItemPath = CloudPath("/nonExistentFile")
		let itemExists = try await provider.checkForItemExistence(at: nonExistentItemPath)
		XCTAssertFalse(itemExists)
	}

	func testCheckForItemExistenceRejectsWithErrorOtherThanItemNotFound() async throws {
		let provider = ConvenienceCloudProviderMock()
		let itemPath = CloudPath("/AAAAA/BBBB")
		await XCTAssertThrowsErrorAsync(try await provider.checkForItemExistence(at: itemPath)) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
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
		let nonExistentItemPath = CloudPath("/nonExistentFile")
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		switch cloudPath {
		case nonExistentItemPath:
			throw CloudProviderError.itemNotFound
		case existingItemPath:
			return CloudItemMetadata(name: "thisFolderExistsInTheCloud", cloudPath: existingItemPath, itemType: .folder, lastModifiedDate: nil, size: nil)
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

	private func deleteItem(at cloudPath: CloudPath) throws {
		let nonExistentItemPath = CloudPath("/nonExistentFolder")
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		switch cloudPath {
		case nonExistentItemPath:
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
