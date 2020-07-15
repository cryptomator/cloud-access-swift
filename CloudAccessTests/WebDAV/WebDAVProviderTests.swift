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
		let responseURL = URL(string: "/Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		provider.fetchItemMetadata(at: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false)).then { metadata in
			XCTAssertTrue(self.client.propfindRequests[responseURL.relativePath] == .zero)
			XCTAssertEqual("About.txt", metadata.name)
			XCTAssertEqual("/Documents/About.txt", metadata.remoteURL.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
			XCTAssertEqual(1074, metadata.size)
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

		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

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

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let getData = try getTestData(forResource: "item-data", withExtension: "txt")
		let getResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: getData, response: getResponse, error: nil))

		provider.downloadFile(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: localURL).then {
			XCTAssertTrue(self.client.getRequests.contains(responseURL.relativePath))
			let expectedData = try self.getTestData(forResource: "item-data", withExtension: "txt")
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
		let responseURL = URL(string: "/Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
		let propfindError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: propfindResponse, error: propfindError))

		let putData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let putResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: putData, response: putResponse, error: nil))

		provider.uploadFile(from: localURL, to: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), replaceExisting: false).then { metadata in
			XCTAssertTrue(self.client.putRequests.contains(responseURL.relativePath))
			XCTAssertEqual("About.txt", metadata.name)
			XCTAssertEqual("/Documents/About.txt", metadata.remoteURL.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
			XCTAssertEqual(1074, metadata.size)
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

		let mkcolResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: mkcolResponse, error: nil))

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
		let responseURL = URL(string: "/Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let deleteResponse = HTTPURLResponse(url: responseURL, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: deleteResponse, error: nil))

		provider.deleteItem(at: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false)).then {
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
		let sourceURL = URL(string: "/Documents/About.txt", relativeTo: baseURL)!
		let destinationURL = URL(string: "/Documents/Foobar.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: sourceURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let moveResponse = HTTPURLResponse(url: sourceURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: moveResponse, error: nil))

		provider.moveItem(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: URL(fileURLWithPath: "/Documents/Foobar.txt", isDirectory: false)).then {
			XCTAssertTrue(self.client.moveRequests[sourceURL.relativePath] == destinationURL.relativePath)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItemWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "deleteItem")
		let sourceURL = URL(string: "/Documents/About.txt", relativeTo: baseURL)!
		let destinationURL = URL(string: "/Documents/Foobar.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: sourceURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let moveData = try getTestData(forResource: "item-move-412-error", withExtension: "xml")
		let moveResponse = HTTPURLResponse(url: sourceURL, statusCode: 412, httpVersion: "HTTP/1.1", headerFields: nil)
		let moveError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: moveData, response: moveResponse, error: moveError))

		provider.moveItem(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: URL(fileURLWithPath: "/Documents/Foobar.txt", isDirectory: false)).then {
			XCTFail("Moving item to an existing resource should fail")
		}.catch { error in
			XCTAssertTrue(self.client.moveRequests[sourceURL.relativePath] == destinationURL.relativePath)
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	// MARK: - Internal

	private func getTestData(forResource name: String, withExtension ext: String) throws -> Data {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: name, withExtension: ext) else {
			throw WebDAVProviderTestsError.missingTestResource
		}
		return try Data(contentsOf: fileURL)
	}
}
