//
//  WebDAVProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 14.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

enum WebDAVProviderTestsError: Error {
	case missingTestResource
}

class WebDAVProviderTests: XCTestCase {
	var tmpDirURL: URL!
	var baseURL: URL!
	var client: WebDAVClientMock!
	var provider: WebDAVProvider!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		baseURL = URL(string: "/cloud/remote.php/webdav/")
		client = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolMock.self)
		provider = try WebDAVProvider(with: client)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).then { metadata in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual("About.txt", metadata.name)
			XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
			XCTAssertEqual(1074, metadata.size)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).then { _ in
			XCTFail("Fetching metdata of a non-existing item should fail")
		}.catch { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemMetadataWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata with unauthorized error")
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		unauthorizedProvider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).then { _ in
			XCTFail("Fetching metdata with an unauthorized client should fail")
		}.catch { error in
			XCTAssertEqual(.zero, unauthorizedClient.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemMetadataWithMissingResourcetype() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata-missing-resourcetype", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).then { metadata in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual("About.txt", metadata.name)
			XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
			XCTAssertEqual(1074, metadata.size)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemList() throws {
		let expectation = XCTestExpectation(description: "fetchItemList")

		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == self.baseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).then { itemList in
			XCTAssertEqual(.one, self.client.propfindRequests["."])
			XCTAssertEqual(5, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Documents" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Nextcloud Manual.pdf" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Nextcloud intro.mp4" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Nextcloud.png" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "Photos" }))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "fetchItemList with itemNotFound error")

		let propfindResponse = HTTPURLResponse(url: baseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == self.baseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).then { _ in
			XCTFail("Fetching item list for a non-existing folder should fail")
		}.catch { error in
			XCTAssertEqual(.one, self.client.propfindRequests["."])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		provider.fetchItemList(forFolderAt: CloudPath("/Documents/About.txt"), withPageToken: nil).then { _ in
			XCTFail("Fetching item list for a folder that is actually a file should fail")
		}.catch { error in
			XCTAssertEqual(.one, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "fetchItemList with unauthorized error")
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let failureResponse = HTTPURLResponse(url: baseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		unauthorizedProvider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).then { _ in
			XCTFail("Fetching item list with an unauthorized client should fail")
		}.catch { error in
			XCTAssertEqual(.one, unauthorizedClient.propfindRequests["."])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			guard case CloudProviderError.unauthorized = error else {
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
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let getData = try getTestData(forResource: "item-data", withExtension: "txt")
		let getResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (getResponse, getData)
		})

		provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).then {
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.getRequests.contains("Documents/About.txt"))
			let expectedData = try self.getTestData(forResource: "item-data", withExtension: "txt")
			let actualData = try Data(contentsOf: localURL)
			XCTAssertEqual(expectedData, actualData)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let getResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (getResponse, nil)
		})

		provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).then {
			XCTFail("Downloading non-existing file should fail")
		}.catch { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.getRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let getData = try getTestData(forResource: "item-data", withExtension: "txt")
		let getResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (getResponse, getData)
		})

		provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).then {
			XCTFail("Downloading file to an existing resource should fail")
		}.catch { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.getRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).then {
			XCTFail("Downloading file that is actually a folder should fail")
		}.catch { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, self.client.getRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFileWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "downloadFile with unauthorized error")
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		unauthorizedProvider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).then {
			XCTFail("Downloading file with an unauthorized client should fail")
		}.catch { error in
			XCTAssertEqual(.zero, unauthorizedClient.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, unauthorizedClient.getRequests.count)
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			guard case CloudProviderError.unauthorized = error else {
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

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		let putResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!
		let putData = Data()
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (putResponse, putData)
		})

		let propfindResponseAfterUpload = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		let propfindDataAfterUpload = try getTestData(forResource: "item-metadata", withExtension: "xml")
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponseAfterUpload, propfindDataAfterUpload)
		})

		provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).then { metadata in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.putRequests.contains("Documents/About.txt"))
			XCTAssertEqual("About.txt", metadata.name)
			XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
			XCTAssertEqual(1074, metadata.size)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let putData = Data()
		let putResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (putResponse, putData)
		})

		let propfindResponseAfterUpload = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		let propfindDataAfterUpload = try getTestData(forResource: "item-metadata", withExtension: "xml")
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponseAfterUpload, propfindDataAfterUpload)
		})

		provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true).then { metadata in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.putRequests.contains("Documents/About.txt"))
			XCTAssertEqual("About.txt", metadata.name)
			XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
			XCTAssertEqual(1074, metadata.size)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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
		provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true).then { _ in
			XCTFail("Uploading non-existing file should fail")
		}.catch { error in
			XCTAssertEqual(0, self.client.propfindRequests.count)
			XCTAssertEqual(0, self.client.putRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).then { _ in
			XCTFail("Uploading file to an existing item should fail")
		}.catch { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, self.client.putRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		let putError = POSIXError(.EISDIR)
		URLProtocolMock.requestHandler.append({ _ in
			throw putError
		})

		provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).then { _ in
			XCTFail("Uploading file that is actually a folder should fail")
		}.catch { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.putRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithReplaceExistingAndAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with replaceExisting and itemAlreadyExists error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true).then { _ in
			XCTFail("Uploading and replacing file that is actually a folder should fail")
		}.catch { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, self.client.putRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.itemAlreadyExists = error else {
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

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		let putResponse = HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (putResponse, nil)
		})
		provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).then { _ in
			XCTFail("Uploading file into a non-existing parent folder should fail")
		}.catch { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.putRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithParentFolderDoesNotExistErrorWhenReceiving404Error() throws {
		let expectation = XCTestExpectation(description: "uploadFile with parentFolderDoesNotExist error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		let putResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (putResponse, nil)
		})
		provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).then { _ in
			XCTFail("Uploading file into a non-existing parent folder should fail")
		}.catch { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.putRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with unauthorized error")
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		unauthorizedProvider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).then { _ in
			XCTFail("Uploading file with an unauthorized client should fail")
		}.catch { error in
			XCTAssertEqual(.zero, unauthorizedClient.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, unauthorizedClient.putRequests.count)
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			guard case CloudProviderError.unauthorized = error else {
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

		let mkcolResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (mkcolResponse, nil)
		})
		provider.createFolder(at: CloudPath("/foo")).then {
			XCTAssertTrue(self.client.mkcolRequests.contains("foo"))
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

		let mkcolResponse = HTTPURLResponse(url: responseURL, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (mkcolResponse, nil)
		})
		provider.createFolder(at: CloudPath("/foo")).then {
			XCTFail("Creating folder at an existing item should fail")
		}.catch { error in
			XCTAssertTrue(self.client.mkcolRequests.contains("foo"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
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

		let mkcolResponse = HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (mkcolResponse, nil)
		})
		provider.createFolder(at: CloudPath("/foo")).then {
			XCTFail("Creating folder at a non-existing parent folder should fail")
		}.catch { error in
			XCTAssertTrue(self.client.mkcolRequests.contains("foo"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolderWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "createFolder with unauthorized error")
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = URL(string: "foo/", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		unauthorizedProvider.createFolder(at: CloudPath("/foo")).then {
			XCTFail("Creating folder with an unauthorized client should fail")
		}.catch { error in
			XCTAssertTrue(unauthorizedClient.mkcolRequests.contains("foo"))
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFile() throws {
		let expectation = XCTestExpectation(description: "deleteFile")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let deleteResponse = HTTPURLResponse(url: responseURL, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (deleteResponse, nil)
		})
		provider.deleteFile(at: CloudPath("/Documents/About.txt")).then {
			XCTAssertTrue(self.client.deleteRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "deleteFile with itemNotFound error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let deleteResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (deleteResponse, nil)
		})

		provider.deleteFile(at: CloudPath("/Documents/About.txt")).then {
			XCTFail("Deleting non-existing item should fail")
		}.catch { error in
			XCTAssertTrue(self.client.deleteRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFileWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "deleteFile with unauthorized error")
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		unauthorizedProvider.deleteFile(at: CloudPath("/Documents/About.txt")).then {
			XCTFail("Deleting an item with an unauthorized client should fail")
		}.catch { error in
			XCTAssertTrue(unauthorizedClient.deleteRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFile() throws {
		let expectation = XCTestExpectation(description: "moveFile")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, nil)
		})

		provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).then {
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "moveFile with itemNotFound error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, nil)
		})

		provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).then {
			XCTFail("Moving non-existing item should fail")
		}.catch { error in
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFileWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "moveFile with itemAlreadyExists error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let moveData = try getTestData(forResource: "item-move-412-error", withExtension: "xml")
		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 412, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, moveData)
		})

		provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).then {
			XCTFail("Moving item to an existing resource should fail")
		}.catch { error in
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFileWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "moveFile with parentFolderDoesNotExist error")
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, nil)
		})

		provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).then {
			XCTFail("Moving item to a non-existing parent folder should fail")
		}.catch { error in
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveFileWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "moveFile with unauthorized error")
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		unauthorizedProvider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).then {
			XCTFail("Moving an item with an unauthorized client should fail")
		}.catch { error in
			XCTAssertEqual("Documents/Foobar.txt", unauthorizedClient.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			guard case CloudProviderError.unauthorized = error else {
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
