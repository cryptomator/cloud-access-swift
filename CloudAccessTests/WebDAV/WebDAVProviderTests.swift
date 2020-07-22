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

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		provider.fetchItemMetadata(at: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false)).then { metadata in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
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

	func testFetchItemMetadataWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata with itemNotFound error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
		let propfindError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: propfindResponse, error: propfindError))

		provider.fetchItemMetadata(at: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false)).then { _ in
			XCTFail("Fetching metdata of a non-existing item should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemMetadataWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata with itemTypeMismatch error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		provider.fetchItemMetadata(at: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: true)).then { _ in
			XCTFail("Fetching metadata of a folder that is actually a file should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemList() throws {
		let expectation = XCTestExpectation(description: "fetchItemList")

		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		provider.fetchItemList(forFolderAt: URL(fileURLWithPath: "/", isDirectory: true), withPageToken: nil).then { itemList in
			XCTAssertTrue(self.client.propfindRequests["/"] == .one)
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

	func testFetchItemListWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "fetchItemList with itemNotFound error")

		let propfindResponse = HTTPURLResponse(url: baseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
		let propfindError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: propfindResponse, error: propfindError))

		provider.fetchItemList(forFolderAt: URL(fileURLWithPath: "/", isDirectory: true), withPageToken: nil).then { _ in
			XCTFail("Fetching item list for a non-existing folder should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/"] == .one)
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "fetchItemList with itemTypeMismatch error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		provider.fetchItemList(forFolderAt: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: true), withPageToken: nil).then { _ in
			XCTFail("Fetching item list for a folder that is actually a file should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .one)
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFile() throws {
		let expectation = XCTestExpectation(description: "downloadFile")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let getData = try getTestData(forResource: "item-data", withExtension: "txt")
		let getResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: getData, response: getResponse, error: nil))

		provider.downloadFile(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: localURL).then {
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.getRequests.contains("/Documents/About.txt"))
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

	func testDownloadFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "downloadFile with itemNotFound error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let getResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
		let getError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: getResponse, error: getError))

		provider.downloadFile(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: localURL).then {
			XCTFail("Downloading non-existing file should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.getRequests.contains("/Documents/About.txt"))
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFileWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "downloadFile with itemAlreadyExists error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let getData = try getTestData(forResource: "item-data", withExtension: "txt")
		let getResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: getData, response: getResponse, error: nil))

		provider.downloadFile(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: localURL).then {
			XCTFail("Downloading file to an existing resource should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.getRequests.contains("/Documents/About.txt"))
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFileWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "downloadFile with itemTypeMismatch error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		provider.downloadFile(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: localURL).then {
			XCTFail("Downloading file that is actually a folder should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertEqual(0, self.client.getRequests.count)
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFile() throws {
		let expectation = XCTestExpectation(description: "uploadFile")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
		let propfindError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: propfindResponse, error: propfindError))

		let putData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let putResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: putData, response: putResponse, error: nil))

		provider.uploadFile(from: localURL, to: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), replaceExisting: false).then { metadata in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.putRequests.contains("/Documents/About.txt"))
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

	func testUploadFileWithReplaceExisting() throws {
		let expectation = XCTestExpectation(description: "uploadFile with replaceExisting")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let putData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let putResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: putData, response: putResponse, error: nil))

		provider.uploadFile(from: localURL, to: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), replaceExisting: true).then { metadata in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.putRequests.contains("/Documents/About.txt"))
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

	func testUploadFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with itemNotFound error")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		provider.uploadFile(from: localURL, to: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), replaceExisting: true).then { _ in
			XCTFail("Uploading non-existing file should fail")
		}.catch { error in
			XCTAssertEqual(0, self.client.propfindRequests.count)
			XCTAssertEqual(0, self.client.putRequests.count)
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with itemAlreadyExists error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		provider.uploadFile(from: localURL, to: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), replaceExisting: false).then { _ in
			XCTFail("Uploading file to an existing item should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertEqual(0, self.client.putRequests.count)
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with itemTypeMismatch error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false, attributes: nil)

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
		let propfindError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: propfindResponse, error: propfindError))

		let putError = POSIXError(.EISDIR)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: nil, error: putError))

		provider.uploadFile(from: localURL, to: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), replaceExisting: false).then { _ in
			XCTFail("Uploading file that is actually a folder should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.putRequests.contains("/Documents/About.txt"))
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithReplaceExistingAndTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with replaceExisting and itemTypeMismatch error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		provider.uploadFile(from: localURL, to: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), replaceExisting: true).then { _ in
			XCTFail("Uploading and replacing file that is actually a folder should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertEqual(0, self.client.putRequests.count)
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with parentFolderDoesNotExist error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
		let propfindError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: propfindResponse, error: propfindError))

		let putResponse = HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil)
		let putError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: putResponse, error: putError))

		provider.uploadFile(from: localURL, to: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), replaceExisting: false).then { _ in
			XCTFail("Uploading file into a non-existing parent folder should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.putRequests.contains("/Documents/About.txt"))
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolder() throws {
		let expectation = XCTestExpectation(description: "createFolder")
		let responseURL = URL(string: "foo/", relativeTo: baseURL)!

		let mkcolResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: mkcolResponse, error: nil))

		provider.createFolder(at: URL(fileURLWithPath: "/foo", isDirectory: true)).then {
			XCTAssertTrue(self.client.mkcolRequests.contains("/foo"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolderWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "createFolder with itemAlreadyExists error")
		let responseURL = URL(string: "foo/", relativeTo: baseURL)!

		let mkcolResponse = HTTPURLResponse(url: responseURL, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)
		let mkcolError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: mkcolResponse, error: mkcolError))

		provider.createFolder(at: URL(fileURLWithPath: "/foo", isDirectory: true)).then {
			XCTFail("Creating folder at an existing item should fail")
		}.catch { error in
			XCTAssertTrue(self.client.mkcolRequests.contains("/foo"))
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolderWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "createFolder with parentFolderDoesNotExist error")
		let responseURL = URL(string: "foo/", relativeTo: baseURL)!

		let mkcolResponse = HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil)
		let mkcolError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: mkcolResponse, error: mkcolError))

		provider.createFolder(at: URL(fileURLWithPath: "/foo", isDirectory: true)).then {
			XCTFail("Creating folder at a non-existing parent folder should fail")
		}.catch { error in
			XCTAssertTrue(self.client.mkcolRequests.contains("/foo"))
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteItem() throws {
		let expectation = XCTestExpectation(description: "deleteItem")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let deleteResponse = HTTPURLResponse(url: responseURL, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: deleteResponse, error: nil))

		provider.deleteItem(at: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false)).then {
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.deleteRequests.contains("/Documents/About.txt"))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteItemWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "deleteItem with itemNotFound error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let deleteResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
		let deleteError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: deleteResponse, error: deleteError))

		provider.deleteItem(at: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false)).then {
			XCTFail("Deleting non-existing item should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.deleteRequests.contains("/Documents/About.txt"))
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteItemWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "deleteItem with itemTypeMismatch error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		provider.deleteItem(at: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false)).then {
			XCTFail("Deleting file that is actually a folder should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertEqual(0, self.client.deleteRequests.count)
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItem() throws {
		let expectation = XCTestExpectation(description: "moveItem")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: moveResponse, error: nil))

		provider.moveItem(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: URL(fileURLWithPath: "/Documents/Foobar.txt", isDirectory: false)).then {
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.moveRequests["/Documents/About.txt"] == "/Documents/Foobar.txt")
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItemWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "moveItem with itemNotFound error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
		let moveError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: moveResponse, error: moveError))

		provider.moveItem(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: URL(fileURLWithPath: "/Documents/Foobar.txt", isDirectory: false)).then {
			XCTFail("Moving non-existing item should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.moveRequests["/Documents/About.txt"] == "/Documents/Foobar.txt")
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItemWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "moveItem with itemAlreadyExists error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let moveData = try getTestData(forResource: "item-move-412-error", withExtension: "xml")
		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 412, httpVersion: "HTTP/1.1", headerFields: nil)
		let moveError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: moveData, response: moveResponse, error: moveError))

		provider.moveItem(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: URL(fileURLWithPath: "/Documents/Foobar.txt", isDirectory: false)).then {
			XCTFail("Moving item to an existing resource should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.moveRequests["/Documents/About.txt"] == "/Documents/Foobar.txt")
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItemWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "moveItem with itemTypeMismatch error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		provider.moveItem(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: URL(fileURLWithPath: "/Documents/Foobar.txt", isDirectory: false)).then {
			XCTFail("Moving file that is actually a folder should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertEqual(0, self.client.moveRequests.count)
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItemWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "moveItem with parentFolderDoesNotExist error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: propfindData, response: propfindResponse, error: nil))

		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil)
		let moveError = URLSessionErrorMock.expectedFailure
		client.urlSession.completionMocks.append(URLSessionCompletionMock(data: nil, response: moveResponse, error: moveError))

		provider.moveItem(from: URL(fileURLWithPath: "/Documents/About.txt", isDirectory: false), to: URL(fileURLWithPath: "/Documents/Foobar.txt", isDirectory: false)).then {
			XCTFail("Moving item to a non-existing parent folder should fail")
		}.catch { error in
			XCTAssertTrue(self.client.propfindRequests["/Documents/About.txt"] == .zero)
			XCTAssertTrue(self.client.moveRequests["/Documents/About.txt"] == "/Documents/Foobar.txt")
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
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
