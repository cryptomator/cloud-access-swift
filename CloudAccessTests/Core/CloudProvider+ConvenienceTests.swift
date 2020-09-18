//
//  CloudProvider+ConvenienceTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 26.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
import XCTest
@testable import CloudAccess

class CloudProvider_ConvenienceTests: XCTestCase {
	func testFetchItemListExhaustively() {
		let expectation = XCTestExpectation(description: "fetchItemListExhaustively")
		let provider = ConvenienceCloudProviderMock()
		provider.fetchItemListExhaustively(forFolderAt: CloudPath("/")).then { cloudItemList in
			XCTAssertEqual(6, cloudItemList.items.count)
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "a" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "b" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "c" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "d" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "e" }))
			XCTAssertTrue(cloudItemList.items.contains(where: { $0.name == "f" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFolderIfExistsFulfillsForMissingItem() {
		let expectation = XCTestExpectation(description: "deleteFolderIfExists fulfills if the item does not exist in the cloud")
		let nonExistentItemPath = CloudPath("/nonExistentFolder")
		let provider = ConvenienceCloudProviderMock()
		provider.deleteFolderIfExists(at: nonExistentItemPath).catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFolderIfExistsFulfillsForExistingItem() {
		let expectation = XCTestExpectation(description: "deleteFolderIfExists fulfills if the item does exist in the cloud")
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		let provider = ConvenienceCloudProviderMock()
		provider.deleteFolderIfExists(at: existingItemPath).catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFolderIfExistsRejectsWithErrorOtherThanItemNotFound() {
		let expectation = XCTestExpectation(description: "deleteFolderIfExists rejects if deleteItem rejects with an error other than CloudProviderError.itemNotFound")
		let itemPath = CloudPath("/AAAAA/BBBB")
		let provider = ConvenienceCloudProviderMock()
		provider.deleteFolderIfExists(at: itemPath).then {
			XCTFail("Promise fulfilled although we expect an CloudProviderError.noInternetConnection")
		}.catch { error in
			guard case CloudProviderError.noInternetConnection = error else {
				XCTFail("Received unexpected error: \(error)")
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCheckForItemExistenceFulfillsForExistingItem() {
		let expectation = XCTestExpectation(description: "checkForItemExistence fulfills with true if the item exists")
		let provider = ConvenienceCloudProviderMock()
		let existingItemPath = CloudPath("/thisFolderExistsInTheCloud")
		provider.checkForItemExistence(at: existingItemPath).then { itemExists in
			XCTAssertTrue(itemExists)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCheckForItemExistenceFulfillsForMissingItem() {
		let expectation = XCTestExpectation(description: "checkForItemExistence fulfills with false if the item does not exist")
		let provider = ConvenienceCloudProviderMock()
		let nonExistentItemPath = CloudPath("/nonExistentFile")
		provider.checkForItemExistence(at: nonExistentItemPath).then { itemExists in
			XCTAssertFalse(itemExists)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCheckForItemExistenceRejectsWithErrorOtherThanItemNotFound() {
		let expectation = XCTestExpectation(description: "checkForItemExistence rejects if fetchItemMetadata rejects with an error other than CloudProviderError.itemNotFound")
		let provider = ConvenienceCloudProviderMock()
		let itemPath = CloudPath("/AAAAA/BBBB")
		provider.checkForItemExistence(at: itemPath).then { _ in
			XCTFail("Promise fulfilled although we expect an CloudProviderError.noInternetConnection")
		}.catch { error in
			guard case CloudProviderError.noInternetConnection = error else {
				XCTFail("Received unexpected error: \(error)")
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
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

	func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
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
