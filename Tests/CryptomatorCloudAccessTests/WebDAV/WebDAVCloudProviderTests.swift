//
//  WebDAVCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 14.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

enum WebDAVProviderTestsError: Error {
	case missingTestResource
}

class WebDAVCloudProviderTests: XCTestCase {
	var tmpDirURL: URL!
	var baseURL: URL!
	var client: WebDAVClientMock!
	var provider: WebDAVCloudProvider!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		baseURL = URL(string: "/cloud/remote.php/webdav/")
		client = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolMock.self)
		provider = try WebDAVCloudProvider(client: client)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		URLProtocolAuthenticationMock.authenticationChallenges = []
		URLProtocolSequenceMock.steps = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt"))
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT"), metadata.lastModifiedDate)
		XCTAssertEqual(1074, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFetchItemMetadataWithNotFoundError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt"))) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testFetchItemMetadataWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVCloudProvider(client: unauthorizedClient)

		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.fetchItemMetadata(at: CloudPath("/Documents/About.txt"))) { error in
			XCTAssertEqual(.zero, unauthorizedClient.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testFetchItemMetadataWithCancelledRequest() async throws {
		URLProtocolMock.requestHandler.append({ _ in
			throw URLError(.cancelled)
		})

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt"))) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}

	func testFetchItemMetadataWithMissingResourcetype() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let propfindData = try getTestData(forResource: "item-metadata-missing-resourcetype", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt"))
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT"), metadata.lastModifiedDate)
		XCTAssertEqual(1074, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFetchItemList() async throws {
		let baseURL: URL = baseURL
		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == baseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
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
		let baseURL: URL = baseURL
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == baseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)) { error in
			XCTAssertEqual(.one, self.client.propfindRequests["."])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testFetchItemListWithTypeMismatchError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/Documents/About.txt"), withPageToken: nil)) { error in
			XCTAssertEqual(.one, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testFetchItemListWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVCloudProvider(client: unauthorizedClient)

		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)) { error in
			XCTAssertEqual(.one, unauthorizedClient.propfindRequests["."])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testDownloadFile() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path, request.httpMethod == "PROPFIND" else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let getData = try getTestData(forResource: "item-data", withExtension: "txt")
		let getResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path, request.httpMethod == "GET" else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (getResponse, getData)
		})

		let metadata = try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, progress: progress, onTaskCreation: nil)
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertTrue(client.getRequests.contains("Documents/About.txt"))
		let expectedData = try getTestData(forResource: "item-data", withExtension: "txt")
		let actualData = try Data(contentsOf: localURL)
		XCTAssertEqual(expectedData, actualData)
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT"), metadata.lastModifiedDate)
		XCTAssertEqual(expectedData.count, metadata.size)
		XCTAssertEqual(1, progress.fractionCompleted)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: WebDAVCloudProvider = provider
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let getData = try getTestData(forResource: "item-data", withExtension: "txt")
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)
		try enqueueResponse(statusCode: 200, data: getData, for: responseURL, onRequest: {
			XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
		})

		let download = Task {
			try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, progress: nil, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		}
		_ = try await value(of: download)

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(getData, try Data(contentsOf: localURL))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: WebDAVCloudProvider = provider
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		try enqueueResponse(statusCode: 404, for: responseURL)
		try enqueueResponse(statusCode: 201, data: Data(), for: responseURL, onRequest: {
			XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
		})
		try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)

		let upload = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: nil, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		}
		_ = try await value(of: upload)

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadFileWithCancellationDuringOnTaskCreation() async throws {
		let provider: WebDAVCloudProvider = provider
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)
		try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-data", withExtension: "txt"), for: responseURL)

		let download = Task {
			try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, progress: nil, onTaskCreation: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertTrue(error is CancellationError)
		}

		XCTAssertEqual(1, URLProtocolMock.requestHandler.count, "The task of a cancelled download must not be resumed")
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testUploadFileWithCancellationDuringOnTaskCreation() async throws {
		let provider: WebDAVCloudProvider = provider
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
		try enqueueResponse(statusCode: 404, for: responseURL)
		try enqueueResponse(statusCode: 201, data: Data(), for: responseURL)

		let upload = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertTrue(error is CancellationError)
		}

		XCTAssertEqual(1, URLProtocolMock.requestHandler.count, "The task of a cancelled upload must not be resumed")
	}

	/// A task that is cancelled before the session resumed it terminates without the session having registered it, so the session has to complete the call itself.
	func testDownloadFileDoesNotHangWhenOnTaskCreationCancelsTask() async throws {
		let provider: WebDAVCloudProvider = provider
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)

		let download = Task {
			try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, progress: nil, onTaskCreation: { task in
				task.cancel()
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertTrue(error is CancellationError)
		}

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	/// See the rationale on the download variant.
	func testUploadFileDoesNotHangWhenOnTaskCreationCancelsTask() async throws {
		let provider: WebDAVCloudProvider = provider
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
		try enqueueResponse(statusCode: 404, for: responseURL)

		let upload = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: nil, onTaskCreation: { task in
				task.cancel()
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertTrue(error is CancellationError)
		}

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// The rejected authentication challenge must not end the call: the session still uses the task until its terminal delegate call.
	func testDownloadFileWithUnauthorizedTransferReturnsAfterTaskCompletion() async throws {
		let (gatedProvider, gate) = try makeGatedProvider()
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolSequenceMock.steps.append(.response(propfindResponse, propfindData))

		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolSequenceMock.steps.append(.authChallenge(URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)))

		let returned = XCTestExpectation(description: "downloadFile returned before the task completed")
		returned.isInverted = true
		let download = Task {
			defer { returned.fulfill() }
			return try await gatedProvider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL)
		}
		await fulfillment(of: [gate.challengeRejected], timeout: testWaitTimeout)
		await fulfillment(of: [returned], timeout: 0.2)
		gate.completionGate.signal()
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}

		XCTAssertTrue(URLProtocolSequenceMock.steps.isEmpty)
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	/// See the rationale on the download variant.
	func testUploadFileWithUnauthorizedTransferReturnsAfterTaskCompletion() async throws {
		let (gatedProvider, gate) = try makeGatedProvider()
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolSequenceMock.steps.append(.response(propfindResponse, nil))

		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolSequenceMock.steps.append(.authChallenge(URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)))

		let returned = XCTestExpectation(description: "uploadFile returned before the task completed")
		returned.isInverted = true
		let upload = Task {
			defer { returned.fulfill() }
			return try await gatedProvider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false)
		}
		await fulfillment(of: [gate.challengeRejected], timeout: testWaitTimeout)
		await fulfillment(of: [returned], timeout: 0.2)
		gate.completionGate.signal()
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}

		XCTAssertTrue(URLProtocolSequenceMock.steps.isEmpty)
	}

	func testDownloadFileWithTransportError() async throws {
		let provider: WebDAVCloudProvider = provider
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)
		URLProtocolMock.requestHandler.append({ _ in
			throw URLProtocolMockError.simulatedTransportFailure
		})

		let download = Task {
			try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL)
		}
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			// Transport failures must not be silently mapped to a `CloudProviderError` — that would
			// hide the actual failure from callers. The exact wrapping URLSession applies to the
			// `URLProtocol`-thrown error is opaque, so we assert the regression of interest.
			XCTAssertNil(error as? CloudProviderError, "Transport failure was unexpectedly mapped: \(error)")
		}

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testUploadFileWithTransportError() async throws {
		let provider: WebDAVCloudProvider = provider
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
		try enqueueResponse(statusCode: 404, for: responseURL)
		URLProtocolMock.requestHandler.append({ _ in
			throw URLProtocolMockError.simulatedTransportFailure
		})

		let upload = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false)
		}
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			// See the download variant for why we assert "not a CloudProviderError"
			// rather than equality against `URLProtocolMockError.simulatedTransportFailure`.
			XCTAssertNil(error as? CloudProviderError, "Transport failure was unexpectedly mapped: \(error)")
		}

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadFileWithNotFoundError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let getResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (getResponse, nil)
		})

		let progress = Progress(totalUnitCount: 1)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, progress: progress, onTaskCreation: nil)) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.getRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
		XCTAssertLessThan(progress.fractionCompleted, 1)
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testDownloadFileWithAlreadyExistsError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let getData = try getTestData(forResource: "item-data", withExtension: "txt")
		let getResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (getResponse, getData)
		})

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL)) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.getRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithTypeMismatchError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL)) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, self.client.getRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVCloudProvider(client: unauthorizedClient)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL)) { error in
			XCTAssertEqual(.zero, unauthorizedClient.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, unauthorizedClient.getRequests.count)
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testUploadFile() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		let putResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil))
		let putData = Data()
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (putResponse, putData)
		})

		let propfindResponseAfterUpload = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		let propfindDataAfterUpload = try getTestData(forResource: "item-metadata", withExtension: "xml")
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponseAfterUpload, propfindDataAfterUpload)
		})

		let progress = Progress(totalUnitCount: 1)
		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertTrue(client.putRequests.contains("Documents/About.txt"))
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT"), metadata.lastModifiedDate)
		XCTAssertEqual(1074, metadata.size)
		XCTAssertEqual(1, progress.fractionCompleted)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// The upload is committed once the `PUT` request was sent, so a cancellation after that must not hide its result.
	func testUploadFileWithCancellationDuringTransfer() async throws {
		let provider: WebDAVCloudProvider = provider
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
		let progress = Progress(totalUnitCount: 1)
		let putStarted = XCTestExpectation(description: "PUT request started")
		let putGate = DispatchSemaphore(value: 0)
		try enqueueResponse(statusCode: 404, for: responseURL)
		try enqueueResponse(statusCode: 201, data: Data(), for: responseURL, onRequest: {
			putStarted.fulfill()
			_ = putGate.wait(timeout: .now() + testWaitTimeout)
		})
		try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)

		let upload = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)
		}
		await fulfillment(of: [putStarted], timeout: testWaitTimeout)
		XCTAssertLessThan(progress.fractionCompleted, 1)
		upload.cancel()
		putGate.signal()
		let metadata = try await value(of: upload)

		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT"), metadata.lastModifiedDate)
		XCTAssertEqual(1, progress.fractionCompleted)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadFileWithQuotaInsufficientError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
		let progress = Progress(totalUnitCount: 1)
		try enqueueResponse(statusCode: 404, for: responseURL)
		try enqueueResponse(statusCode: 507, for: responseURL)

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)) { error in
			XCTAssertEqual(CloudProviderError.quotaInsufficient, error as? CloudProviderError)
		}
		XCTAssertLessThan(progress.fractionCompleted, 1)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadFileWithReplaceExisting() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let putData = Data()
		let putResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (putResponse, putData)
		})

		let propfindResponseAfterUpload = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		let propfindDataAfterUpload = try getTestData(forResource: "item-metadata", withExtension: "xml")
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponseAfterUpload, propfindDataAfterUpload)
		})

		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true)
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertTrue(client.putRequests.contains("Documents/About.txt"))
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT"), metadata.lastModifiedDate)
		XCTAssertEqual(1074, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadFileWithNotFoundError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true)) { error in
			XCTAssertEqual(0, self.client.propfindRequests.count)
			XCTAssertEqual(0, self.client.putRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testUploadFileWithAlreadyExistsError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false)) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, self.client.putRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testUploadFileWithTypeMismatchError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false, attributes: nil)

		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
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

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false)) { error in
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testUploadFileWithReplaceExistingAndAlreadyExistsError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true)) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, self.client.putRequests.count)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testUploadFileWithParentFolderDoesNotExistError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		let putResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (putResponse, nil)
		})
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false)) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.putRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testUploadFileWithParentFolderDoesNotExistErrorWhenReceiving404Error() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, nil)
		})

		let putResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (putResponse, nil)
		})
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false)) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.putRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testUploadFileWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVCloudProvider(client: unauthorizedClient)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false)) { error in
			XCTAssertEqual(.zero, unauthorizedClient.propfindRequests["Documents/About.txt"])
			XCTAssertEqual(0, unauthorizedClient.putRequests.count)
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testCreateFolder() async throws {
		let responseURL = try XCTUnwrap(URL(string: "foo/", relativeTo: baseURL))

		let mkcolResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (mkcolResponse, nil)
		})
		try await provider.createFolder(at: CloudPath("/foo"))
		XCTAssertTrue(client.mkcolRequests.contains("foo"))
	}

	func testCreateFolderWithAlreadyExistsError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "foo/", relativeTo: baseURL))

		let mkcolResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (mkcolResponse, nil)
		})
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: CloudPath("/foo"))) { error in
			XCTAssertTrue(self.client.mkcolRequests.contains("foo"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testCreateFolderWithParentFolderDoesNotExistError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "foo/", relativeTo: baseURL))

		let mkcolResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (mkcolResponse, nil)
		})
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: CloudPath("/foo"))) { error in
			XCTAssertTrue(self.client.mkcolRequests.contains("foo"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testCreateFolderWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVCloudProvider(client: unauthorizedClient)

		let responseURL = try XCTUnwrap(URL(string: "foo/", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.createFolder(at: CloudPath("/foo"))) { error in
			XCTAssertTrue(unauthorizedClient.mkcolRequests.contains("foo"))
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testDeleteFile() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let deleteResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (deleteResponse, nil)
		})
		try await provider.deleteFile(at: CloudPath("/Documents/About.txt"))
		XCTAssertTrue(client.deleteRequests.contains("Documents/About.txt"))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDeleteFileWithNotFoundError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let deleteResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (deleteResponse, nil)
		})

		await XCTAssertThrowsErrorAsync(try await provider.deleteFile(at: CloudPath("/Documents/About.txt"))) { error in
			XCTAssertTrue(self.client.deleteRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDeleteFileWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVCloudProvider(client: unauthorizedClient)

		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.deleteFile(at: CloudPath("/Documents/About.txt"))) { error in
			XCTAssertTrue(unauthorizedClient.deleteRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testMoveFile() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let moveResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, nil)
		})

		try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt"))
		XCTAssertEqual("Documents/Foobar.txt", client.moveRequests["Documents/About.txt"])
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testMoveFileWithNotFoundError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let moveResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, nil)
		})

		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt"))) { error in
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testMoveFileWithAlreadyExistsError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let moveData = try getTestData(forResource: "item-move-412-error", withExtension: "xml")
		let moveResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 412, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, moveData)
		})

		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt"))) { error in
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testMoveFileWithParentFolderDoesNotExistError() async throws {
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let moveResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (moveResponse, nil)
		})

		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt"))) { error in
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testMoveFileWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVCloudProvider(client: unauthorizedClient)

		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt"))) { error in
			XCTAssertEqual("Documents/Foobar.txt", unauthorizedClient.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(provider)
		XCTAssertTrue(client.propfindRequests.isEmpty)
		XCTAssertTrue(client.getRequests.isEmpty)
		XCTAssertTrue(client.putRequests.isEmpty)
		XCTAssertTrue(client.mkcolRequests.isEmpty)
		XCTAssertTrue(client.deleteRequests.isEmpty)
		XCTAssertTrue(client.moveRequests.isEmpty)
	}

	// MARK: - Internal

	private func getTestData(forResource name: String, withExtension ext: String) throws -> Data {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: name, withExtension: ext) else {
			throw WebDAVProviderTestsError.missingTestResource
		}
		return try Data(contentsOf: fileURL)
	}

	private func enqueueResponse(statusCode: Int, data: Data? = nil, for responseURL: URL, onRequest: @escaping @Sendable () -> Void = {}) throws {
		let response = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			onRequest()
			return (response, data)
		})
	}

	private func makeGatedProvider() throws -> (WebDAVCloudProvider, TransferGate) {
		let credential = WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil)
		let gate = TransferGate()
		let configuration = URLSessionConfiguration.default
		configuration.httpCookieStorage = HTTPCookieStorage()
		configuration.urlCredentialStorage = nil
		configuration.protocolClasses = [URLProtocolSequenceMock.self]
		let client = WebDAVClient(credential: credential, session: WebDAVSession(credential: credential, configuration: configuration, metadataConfiguration: nil, hooks: gate.hooks))
		let provider = try WebDAVCloudProvider(client: client)
		return (provider, gate)
	}
}

/// Holds back the terminal processing of a transfer task until the test opens the gate, so that a test can observe whether a call already returned while its task is still running.
private final class TransferGate: Sendable {
	let challengeRejected = XCTestExpectation(description: "authentication challenge rejected")
	let completionGate = DispatchSemaphore(value: 0)

	var hooks: SplitURLSession.Hooks {
		return SplitURLSession.Hooks(didApplyChallengeDecision: { [challengeRejected] task, decision in
			if decision.disposition == .cancelAuthenticationChallenge, TransferGate.isTransfer(task) {
				challengeRejected.fulfill()
			}
		}, willProcessCompletion: { [completionGate] task in
			if TransferGate.isTransfer(task) {
				_ = completionGate.wait(timeout: .now() + testWaitTimeout)
			}
		})
	}

	private static func isTransfer(_ task: URLSessionTask) -> Bool {
		return task is URLSessionUploadTask || task is URLSessionDownloadTask
	}
}
