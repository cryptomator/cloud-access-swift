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

	func testFetchItemMetadata() async throws {
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).async()
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
		XCTAssertEqual(1074, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFetchItemMetadataWithNotFoundError() async throws {
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).async()) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testFetchItemMetadataWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).async()) { error in
			XCTAssertEqual(.zero, unauthorizedClient.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testFetchItemMetadataWithMissingResourcetype() async throws {
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata-missing-resourcetype", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).async()
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
		XCTAssertEqual(1074, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFetchItemList() async throws {
		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == self.baseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).async()
		XCTAssertEqual(.one, client.propfindRequests["."])
		XCTAssertEqual(5, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Documents" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Nextcloud Manual.pdf" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Nextcloud intro.mp4" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Nextcloud.png" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Photos" }))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFetchItemListWithNotFoundError() async throws {
		let propfindResponse = HTTPURLResponse(url: baseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == self.baseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).async()) { error in
			XCTAssertEqual(.one, self.client.propfindRequests["."])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testFetchItemListWithTypeMismatchError() async throws {
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/Documents/About.txt"), withPageToken: nil).async()) { error in
			XCTAssertEqual(.one, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testFetchItemListWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let failureResponse = HTTPURLResponse(url: baseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).async()) { error in
			XCTAssertEqual(.one, unauthorizedClient.propfindRequests["."])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testDownloadFile() async throws {
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

		try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).async()
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertTrue(client.getRequests.contains("Documents/About.txt"))
		let expectedData = try getTestData(forResource: "item-data", withExtension: "txt")
		let actualData = try Data(contentsOf: localURL)
		XCTAssertEqual(expectedData, actualData)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadFileWithNotFoundError() async throws {
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

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).async()) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.getRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithAlreadyExistsError() async throws {
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

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).async()) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.getRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithTypeMismatchError() async throws {
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

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).async()) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, self.client.getRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).async()) { error in
			XCTAssertEqual(.zero, unauthorizedClient.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, unauthorizedClient.getRequests.count)
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testUploadFile() async throws {
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

		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).async()
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertTrue(client.putRequests.contains("Documents/About.txt"))
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
		XCTAssertEqual(1074, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadFileWithReplaceExisting() async throws {
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

		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true).async()
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertTrue(client.putRequests.contains("Documents/About.txt"))
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT")!, metadata.lastModifiedDate)
		XCTAssertEqual(1074, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadFileWithNotFoundError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true).async()) { error in
			XCTAssertEqual(0, self.client.propfindRequests.count)
			XCTAssertEqual(0, self.client.putRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testUploadFileWithAlreadyExistsError() async throws {
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

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).async()) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, self.client.putRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testUploadFileWithTypeMismatchError() async throws {
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

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).async()) { error in
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testUploadFileWithReplaceExistingAndAlreadyExistsError() async throws {
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

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true).async()) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, self.client.putRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testUploadFileWithParentFolderDoesNotExistError() async throws {
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
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).async()) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.putRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testUploadFileWithParentFolderDoesNotExistErrorWhenReceiving404Error() async throws {
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
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).async()) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.putRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testUploadFileWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).async()) { error in
			XCTAssertEqual(.zero, unauthorizedClient.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, unauthorizedClient.putRequests.count)
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testCreateFolder() async throws {
		let responseURL = URL(string: "foo/", relativeTo: baseURL)!

		let mkcolResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (mkcolResponse, nil)
		})
		try await provider.createFolder(at: CloudPath("/foo")).async()
		XCTAssertTrue(client.mkcolRequests.contains("foo"))
	}

	func testCreateFolderWithAlreadyExistsError() async throws {
		let responseURL = URL(string: "foo/", relativeTo: baseURL)!

		let mkcolResponse = HTTPURLResponse(url: responseURL, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (mkcolResponse, nil)
		})
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: CloudPath("/foo")).async()) { error in
			XCTAssertTrue(self.client.mkcolRequests.contains("foo"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testCreateFolderWithParentFolderDoesNotExistError() async throws {
		let responseURL = URL(string: "foo/", relativeTo: baseURL)!

		let mkcolResponse = HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (mkcolResponse, nil)
		})
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: CloudPath("/foo")).async()) { error in
			XCTAssertTrue(self.client.mkcolRequests.contains("foo"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testCreateFolderWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = URL(string: "foo/", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.createFolder(at: CloudPath("/foo")).async()) { error in
			XCTAssertTrue(unauthorizedClient.mkcolRequests.contains("foo"))
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testDeleteFile() async throws {
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let deleteResponse = HTTPURLResponse(url: responseURL, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (deleteResponse, nil)
		})
		try await provider.deleteFile(at: CloudPath("/Documents/About.txt")).async()
		XCTAssertTrue(client.deleteRequests.contains("Documents/About.txt"))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDeleteFileWithNotFoundError() async throws {
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let deleteResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (deleteResponse, nil)
		})

		await XCTAssertThrowsErrorAsync(try await provider.deleteFile(at: CloudPath("/Documents/About.txt")).async()) { error in
			XCTAssertTrue(self.client.deleteRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDeleteFileWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.deleteFile(at: CloudPath("/Documents/About.txt")).async()) { error in
			XCTAssertTrue(unauthorizedClient.deleteRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testMoveFile() async throws {
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, nil)
		})

		try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).async()
		XCTAssertEqual("Documents/Foobar.txt", client.moveRequests["Documents/About.txt"])
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testMoveFileWithNotFoundError() async throws {
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, nil)
		})

		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).async()) { error in
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testMoveFileWithAlreadyExistsError() async throws {
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let moveData = try getTestData(forResource: "item-move-412-error", withExtension: "xml")
		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 412, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, moveData)
		})

		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).async()) { error in
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testMoveFileWithParentFolderDoesNotExistError() async throws {
		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!

		let moveResponse = HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil)!
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, nil)
		})

		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).async()) { error in
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testMoveFileWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = URL(string: "Documents/About.txt", relativeTo: baseURL)!
		let failureResponse = HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).async()) { error in
			XCTAssertEqual("Documents/Foobar.txt", unauthorizedClient.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
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
