//
//  WebDAVProviderTests.swift
//  CloudAccessTests
//
//  Created by Tobias Hagemann on 14.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
@testable import CloudAccess

enum WebDAVProviderTestsError: Error {
	case missingTestResource
}

class WebDAVProviderTests: XCTestCase {
	var tmpDirURL: URL!
	var baseURL: URL!
	var client: WebDAVClientMock!
	var provider: WebDAVProvider!

	override func setUpWithError() throws {
		tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		baseURL = URL(string: "/cloud/remote.php/webdav/")
		client = WebDAVClientMock(baseURL: baseURL)
		provider = WebDAVProvider(with: client)
	}

	func testFetchItemMetadata() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata")
		let responseURL = URL(string: "/Nextcloud%20Manual.pdf", relativeTo: baseURL)!
		client.urlSession.response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.data = try getData(forResource: "item-metadata", withExtension: "xml")
		provider.fetchItemMetadata(at: URL(fileURLWithPath: "/Nextcloud Manual.pdf", isDirectory: false)).then { metadata in
			XCTAssertTrue(self.client.propfindRequests[responseURL.relativePath] == .zero)
			XCTAssertEqual("Nextcloud Manual.pdf", metadata.name)
			XCTAssertEqual("/Nextcloud Manual.pdf", metadata.remoteURL.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
			XCTAssertEqual(6_837_751, metadata.size)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemList() throws {
		let expectation = XCTestExpectation(description: "fetchItemList")
		let responseURL = URL(string: "/", relativeTo: baseURL)!
		client.urlSession.response = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.data = try getData(forResource: "item-list", withExtension: "xml")
		provider.fetchItemList(forFolderAt: URL(fileURLWithPath: "/", isDirectory: true), withPageToken: nil).then { itemList in
			XCTAssertTrue(self.client.propfindRequests[responseURL.relativePath] == .one)
			XCTAssertEqual(5, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Documents" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Nextcloud Manual.pdf" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Nextcloud intro.mp4" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Nextcloud.png" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Photos" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFile() throws {
		let expectation = XCTestExpectation(description: "downloadFile")
		let responseURL = URL(string: "/Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		client.urlSession.response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.data = try getData(forResource: "item-read", withExtension: "txt")
		provider.downloadFile(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: localURL).then {
			XCTAssertTrue(self.client.getRequests.contains(responseURL.relativePath))
			let expectedData = try self.getData(forResource: "item-read", withExtension: "txt")
			let actualData = try Data(contentsOf: localURL)
			XCTAssertEqual(expectedData, actualData)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFile() throws {
		let expectation = XCTestExpectation(description: "uploadFile")
		let responseURL = URL(string: "/foo.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getData(forResource: "item-write", withExtension: "txt").write(to: localURL)
		client.urlSession.response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.data = try getData(forResource: "item-write", withExtension: "xml")
		provider.uploadFile(from: localURL, to: URL(fileURLWithPath: "/foo.txt", isDirectory: false), replaceExisting: false).then { metadata in
			XCTAssertTrue(self.client.putRequests.contains(responseURL.relativePath))
			XCTAssertEqual("foo.txt", metadata.name)
			XCTAssertEqual("/foo.txt", metadata.remoteURL.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual(Date.date(fromRFC822: "Tue, 07 Jul 2020 16:55:50 GMT")!, metadata.lastModifiedDate)
			XCTAssertEqual(8193, metadata.size)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolder() throws {
		let expectation = XCTestExpectation(description: "createFolder")
		let responseURL = URL(string: "/foo/", relativeTo: baseURL)!
		client.urlSession.response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		provider.createFolder(at: URL(fileURLWithPath: "/foo", isDirectory: true)).then {
			XCTAssertTrue(self.client.mkcolRequests.contains(responseURL.relativePath))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteItem() throws {
		let expectation = XCTestExpectation(description: "deleteItem")
		let responseURL = URL(string: "/foo.txt", relativeTo: baseURL)!
		client.urlSession.response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		provider.deleteItem(at: URL(fileURLWithPath: "/foo.txt", isDirectory: false)).then {
			XCTAssertTrue(self.client.deleteRequests.contains(responseURL.relativePath))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItem() throws {
		let expectation = XCTestExpectation(description: "deleteItem")
		let sourceURL = URL(string: "/foo/", relativeTo: baseURL)!
		let destinationURL = URL(string: "/bar/", relativeTo: baseURL)!
		client.urlSession.response = HTTPURLResponse(url: sourceURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		provider.moveItem(from: URL(fileURLWithPath: "/foo", isDirectory: true), to: URL(fileURLWithPath: "/bar", isDirectory: true)).then {
			XCTAssertTrue(self.client.moveRequests[sourceURL.relativePath] == destinationURL.relativePath)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	// MARK: - Internal

	private func getData(forResource name: String, withExtension ext: String) throws -> Data {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: name, withExtension: ext) else {
			throw WebDAVProviderTestsError.missingTestResource
		}
		return try Data(contentsOf: fileURL)
	}
}
