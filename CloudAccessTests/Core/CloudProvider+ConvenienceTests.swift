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
	func testFetchItemListExhaustively() throws {
		let expectation = XCTestExpectation(description: "fetchItemListExhaustively")
		let provider = PaginatedCloudProviderMock()

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
}

class PaginatedCloudProviderMock: CloudProvider {
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

	func fetchItemMetadata(at _: URL) -> Promise<CloudItemMetadata> {
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

	func downloadFile(from _: URL, to _: URL, progress _: Progress?) -> Promise<CloudItemMetadata> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func uploadFile(from _: URL, to _: URL, isUpdate _: Bool, progress _: Progress?) -> Promise<CloudItemMetadata> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func createFolder(at _: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func deleteItem(at _: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	func moveItem(from _: URL, to _: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
}
