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
		provider.fetchItemListExhaustively(forFolderAt: URL(fileURLWithPath: "/")).then { cloudItemList in
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

	func testDeleteItemIfExistsFulfillsForMissingItem() {
		let expectation = XCTestExpectation(description: "deleteItemIfExists fulfills if the item does not exist in the cloud")
		let nonExistentItemURL = URL(fileURLWithPath: "/nonExistentFolder/", isDirectory: true)
		let provider = ConvenienceCloudProviderMock()
		provider.deleteItemIfExists(at: nonExistentItemURL).catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteItemIfExistsFulfillsForExistingItem() {
		let expectation = XCTestExpectation(description: "deleteItemIfExists fulfills if the item does exist in the cloud")
		let existingItemURL = URL(fileURLWithPath: "/thisFolderExistsInTheCloud/", isDirectory: true)
		let provider = ConvenienceCloudProviderMock()
		provider.deleteItemIfExists(at: existingItemURL).catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteItemIfExistsRejectsWithErrorOtherThanItemNotFound() {
		let expectation = XCTestExpectation(description: "deleteItemIfExists rejects if deleteItem rejects with an error other than CloudProviderError.itemNotFound")
		let itemURL = URL(fileURLWithPath: "/AAAAA/BBBB/", isDirectory: true)
		let provider = ConvenienceCloudProviderMock()
		provider.deleteItemIfExists(at: itemURL).then {
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
		let existingItemURL = URL(fileURLWithPath: "/thisFolderExistsInTheCloud/", isDirectory: true)
		provider.checkForItemExistence(at: existingItemURL).then { itemExists in
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
		let nonExistentItemURL = URL(fileURLWithPath: "/nonExistentFile", isDirectory: false)
		provider.checkForItemExistence(at: nonExistentItemURL).then { itemExists in
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
		let itemURL = URL(fileURLWithPath: "/AAAAA/BBBB/", isDirectory: true)
		provider.checkForItemExistence(at: itemURL).then { _ in
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
			CloudItemMetadata(name: "a", remoteURL: URL(fileURLWithPath: "/a"), itemType: .file, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "b", remoteURL: URL(fileURLWithPath: "/b"), itemType: .file, lastModifiedDate: nil, size: nil)
		],
		"1": [
			CloudItemMetadata(name: "c", remoteURL: URL(fileURLWithPath: "/c"), itemType: .file, lastModifiedDate: nil, size: nil)
		],
		"2": [
			CloudItemMetadata(name: "d", remoteURL: URL(fileURLWithPath: "/d"), itemType: .file, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "e", remoteURL: URL(fileURLWithPath: "/e"), itemType: .file, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "f", remoteURL: URL(fileURLWithPath: "/f"), itemType: .file, lastModifiedDate: nil, size: nil)
		]
	]

	func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata> {
		let nonExistentItemURL = URL(fileURLWithPath: "/nonExistentFile", isDirectory: false)
		let existingItemURL = URL(fileURLWithPath: "/thisFolderExistsInTheCloud/", isDirectory: true)

		if remoteURL == nonExistentItemURL {
			return Promise(CloudProviderError.itemNotFound)
		}
		if remoteURL == existingItemURL {
			let metadata = CloudItemMetadata(name: "thisFolderExistsInTheCloud", remoteURL: existingItemURL, itemType: .folder, lastModifiedDate: nil, size: nil)
			return Promise(metadata)
		}
		return Promise(CloudProviderError.noInternetConnection)
	}

	func fetchItemList(forFolderAt _: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let items: [CloudItemMetadata]
		let nextToken: String?

		switch pageToken {
		case "1":
			items = pages["1"]!
			nextToken = "2"
		case "2":
			items = pages["2"]!
			nextToken = nil
		default:
			items = pages["0"]!
			nextToken = "1"
		}

		return Promise(CloudItemList(items: items, nextPageToken: nextToken))
	}

	func downloadFile(from _: URL, to _: URL, progress _: Progress?) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func uploadFile(from _: URL, to _: URL, replaceExisting _: Bool, progress _: Progress?) -> Promise<CloudItemMetadata> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func createFolder(at remoteURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func deleteItem(at remoteURL: URL) -> Promise<Void> {
		let nonExistentItemURL = URL(fileURLWithPath: "/nonExistentFolder/", isDirectory: true)
		let existingItemURL = URL(fileURLWithPath: "/thisFolderExistsInTheCloud/", isDirectory: true)

		if remoteURL == nonExistentItemURL {
			return Promise(CloudProviderError.itemNotFound)
		}
		if remoteURL == existingItemURL {
			return Promise(())
		}
		return Promise(CloudProviderError.noInternetConnection)
	}

	func moveItem(from _: URL, to _: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
}
