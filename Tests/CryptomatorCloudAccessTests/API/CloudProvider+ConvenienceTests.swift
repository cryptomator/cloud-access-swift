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
import Promises
import XCTest

class CloudProvider_ConvenienceTests: XCTestCase {
	func testFetchItemListExhaustively() async throws {
		let provider = ConvenienceCloudProviderMock()
		let cloudItemList = try await provider.fetchItemListExhaustively(forFolderAt: CloudPath("/")).async()
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
		try await provider.createFolderIfMissing(at: existingItemPath).async()
	}

	func testCreateFolderIfMissingFulfillsForMissingItem() async throws {
		let nonExistentItemPath = CloudPath("/nonExistentFolder")
		let provider = ConvenienceCloudProviderMock()
		try await provider.createFolderIfMissing(at: nonExistentItemPath).async()
	}

	func testCreateFolderIfMissingRejectsWithErrorOtherThanItemNotFound() async throws {
		let itemPath = CloudPath("/AAAAA/BBBB")
		let provider = ConvenienceCloudProviderMock()
		await XCTAssertThrowsErrorAsync(try await provider.createFolderIfMissing(at: itemPath).async()) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
		}
	}

	func testDeleteFolderIfExistingFulfillsForMissingItem() async throws {
		let nonExistentItemPath = CloudPath("/nonExistentFolder")
		let provider = ConvenienceCloudProviderMock()
		try await provider.deleteFolderIfExisting(at: nonExistentItemPath).async()
	}

	func testDeleteFolderIfExistingFulfillsForExistingItem() async throws {
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		let provider = ConvenienceCloudProviderMock()
		try await provider.deleteFolderIfExisting(at: existingItemPath).async()
	}

	func testDeleteFolderIfExistingRejectsWithErrorOtherThanItemNotFound() async throws {
		let itemPath = CloudPath("/AAAAA/BBBB")
		let provider = ConvenienceCloudProviderMock()
		await XCTAssertThrowsErrorAsync(try await provider.deleteFolderIfExisting(at: itemPath).async()) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
		}
	}

	func testCheckForItemExistenceFulfillsForExistingItem() async throws {
		let provider = ConvenienceCloudProviderMock()
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		let itemExists = try await provider.checkForItemExistence(at: existingItemPath).async()
		XCTAssertTrue(itemExists)
	}

	func testCheckForItemExistenceFulfillsForMissingItem() async throws {
		let provider = ConvenienceCloudProviderMock()
		let nonExistentItemPath = CloudPath("/nonExistentFile")
		let itemExists = try await provider.checkForItemExistence(at: nonExistentItemPath).async()
		XCTAssertFalse(itemExists)
	}

	func testCheckForItemExistenceRejectsWithErrorOtherThanItemNotFound() async throws {
		let provider = ConvenienceCloudProviderMock()
		let itemPath = CloudPath("/AAAAA/BBBB")
		await XCTAssertThrowsErrorAsync(try await provider.checkForItemExistence(at: itemPath).async()) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
		}
	}
}

private class ConvenienceCloudProviderMock: CloudProvider {
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

	func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let nonExistentItemPath = CloudPath("/nonExistentFile")
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		switch cloudPath {
		case nonExistentItemPath:
			return Promise(CloudProviderError.itemNotFound)
		case existingItemPath:
			return Promise(CloudItemMetadata(name: "thisFolderExistsInTheCloud", cloudPath: existingItemPath, itemType: .folder, lastModifiedDate: nil, size: nil))
		default:
			return Promise(CloudProviderError.noInternetConnection)
		}
	}

	func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		switch pageToken {
		case nil:
			return Promise(CloudItemList(items: pages["0"]!, nextPageToken: "1"))
		case "1":
			return Promise(CloudItemList(items: pages["1"]!, nextPageToken: "2"))
		case "2":
			return Promise(CloudItemList(items: pages["2"]!, nextPageToken: nil))
		default:
			return Promise(CloudProviderError.noInternetConnection)
		}
	}

	func downloadFile(from cloudPath: CloudPath, to localURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		let nonExistentItemPath = CloudPath("/nonExistentFolder")
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		switch cloudPath {
		case nonExistentItemPath:
			return Promise(())
		case existingItemPath:
			return Promise(CloudProviderError.itemAlreadyExists)
		default:
			return Promise(CloudProviderError.noInternetConnection)
		}
	}

	func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath)
	}

	func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath)
	}

	private func deleteItem(at cloudPath: CloudPath) -> Promise<Void> {
		let nonExistentItemPath = CloudPath("/nonExistentFolder")
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		switch cloudPath {
		case nonExistentItemPath:
			return Promise(CloudProviderError.itemNotFound)
		case existingItemPath:
			return Promise(())
		default:
			return Promise(CloudProviderError.noInternetConnection)
		}
	}

	func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
}
