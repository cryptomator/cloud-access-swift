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
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
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

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).async()) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testFetchItemMetadataWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).async()) { error in
			XCTAssertEqual(.zero, unauthorizedClient.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
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

		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).async()
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT"), metadata.lastModifiedDate)
		XCTAssertEqual(1074, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFetchItemList() async throws {
		let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
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
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
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
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
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

		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).async()) { error in
			XCTAssertEqual(.one, unauthorizedClient.propfindRequests["."])
			XCTAssertTrue(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
		}
	}

	func testDownloadFile() async throws {
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

		let getData = try getTestData(forResource: "item-data", withExtension: "txt")
		let getResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
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

	/// Uses `XCTestExpectation` instead of `async + .async()` because the buggy path leaves the
	/// promise pending; awaiting it would hang the test runner instead of producing a timeout failure.
	func testDownloadFileDoesNotHangWhenOnTaskCreationResumesBeforeRegistration() throws {
		let (signalingProvider, delegateFired) = try makeSignalingProvider()
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

		let getData = try getTestData(forResource: "item-data", withExtension: "txt")
		let getResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (getResponse, getData)
		})

		let expectation = expectation(description: "downloadFile resolves")
		signalingProvider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, onTaskCreation: { task in
			task?.resume()
			// Force the delegate's transfer-completion callback to run before `onTaskCreation` returns:
			// on the buggy ordering, registration happens after the callback already missed its dict entry.
			_ = delegateFired.wait(timeout: .now() + 2.0)
		}).then {
			expectation.fulfill()
		}.catch { error in
			XCTFail("downloadFile failed: \(error)")
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 2.0)

		let expectedData = try getTestData(forResource: "item-data", withExtension: "txt")
		let actualData = try Data(contentsOf: localURL)
		XCTAssertEqual(expectedData, actualData)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// See the rationale on the download variant for why this test uses `XCTestExpectation`.
	func testUploadFileDoesNotHangWhenOnTaskCreationResumesBeforeRegistration() throws {
		let (signalingProvider, delegateFired) = try makeSignalingProvider()
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
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (putResponse, Data())
		})

		let propfindResponseAfterUpload = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		let propfindDataAfterUpload = try getTestData(forResource: "item-metadata", withExtension: "xml")
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponseAfterUpload, propfindDataAfterUpload)
		})

		let expectation = expectation(description: "uploadFile resolves")
		signalingProvider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, onTaskCreation: { task in
			task?.resume()
			// See the download variant for why this wait is needed.
			_ = delegateFired.wait(timeout: .now() + 2.0)
		}).then { _ in
			expectation.fulfill()
		}.catch { error in
			XCTFail("uploadFile failed: \(error)")
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 2.0)

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// Same registration race that the happy-path test covers, exercised on the auth-rejection
	/// branch of `urlSession(_:task:didReceive challenge:_:)`. See the download variant for why
	/// this test uses `XCTestExpectation`.
	func testDownloadFileRejectsWithUnauthorizedWhenAuthChallengeFiresAfterOnTaskCreationResumes() throws {
		let (signalingProvider, delegateFired) = try makeSignalingProvider(urlProtocolMock: URLProtocolSequenceMock.self)
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolSequenceMock.steps.append(.response(propfindResponse, propfindData))

		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolSequenceMock.steps.append(.authChallenge(URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)))

		let expectation = expectation(description: "downloadFile rejects")
		signalingProvider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, onTaskCreation: { task in
			task?.resume()
			// See the happy-path download variant; here the wait gates on the auth-rejection branch.
			_ = delegateFired.wait(timeout: .now() + 2.0)
		}).then {
			XCTFail("downloadFile should have failed with unauthorized")
			expectation.fulfill()
		}.catch { error in
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 2.0)

		XCTAssertTrue(URLProtocolSequenceMock.steps.isEmpty)
	}

	/// See the rationale on the download auth variant.
	func testUploadFileRejectsWithUnauthorizedWhenAuthChallengeFiresAfterOnTaskCreationResumes() throws {
		let (signalingProvider, delegateFired) = try makeSignalingProvider(urlProtocolMock: URLProtocolSequenceMock.self)
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolSequenceMock.steps.append(.response(propfindResponse, nil))

		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolSequenceMock.steps.append(.authChallenge(URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)))

		let expectation = expectation(description: "uploadFile rejects")
		signalingProvider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, onTaskCreation: { task in
			task?.resume()
			// See the download auth variant.
			_ = delegateFired.wait(timeout: .now() + 2.0)
		}).then { _ in
			XCTFail("uploadFile should have failed with unauthorized")
			expectation.fulfill()
		}.catch { error in
			XCTAssertEqual(CloudProviderError.unauthorized, error as? CloudProviderError)
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 2.0)

		XCTAssertTrue(URLProtocolSequenceMock.steps.isEmpty)
	}

	/// Same registration race exercised on the transport-failure branch of `didCompleteWithError`.
	/// See the download variant for why this test uses `XCTestExpectation`.
	func testDownloadFileRejectsWithTransportErrorAfterOnTaskCreationResumes() throws {
		let (signalingProvider, delegateFired) = try makeSignalingProvider()
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

		URLProtocolMock.requestHandler.append({ _ in
			throw URLProtocolMockError.simulatedTransportFailure
		})

		let expectation = expectation(description: "downloadFile rejects")
		signalingProvider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, onTaskCreation: { task in
			task?.resume()
			// See the happy-path download variant; here the wait gates on the transport-failure branch.
			_ = delegateFired.wait(timeout: .now() + 2.0)
		}).then {
			XCTFail("downloadFile should have failed")
			expectation.fulfill()
		}.catch { error in
			// Transport failures must not be silently mapped to a `CloudProviderError` — that would
			// hide the actual failure from callers. The exact wrapping URLSession applies to the
			// `URLProtocol`-thrown error is opaque, so we assert the regression of interest.
			XCTAssertNil(error as? CloudProviderError, "Transport failure was unexpectedly mapped: \(error)")
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 2.0)

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// See the rationale on the download transport-failure variant.
	func testUploadFileRejectsWithTransportErrorAfterOnTaskCreationResumes() throws {
		let (signalingProvider, delegateFired) = try makeSignalingProvider()
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

		URLProtocolMock.requestHandler.append({ _ in
			throw URLProtocolMockError.simulatedTransportFailure
		})

		let expectation = expectation(description: "uploadFile rejects")
		signalingProvider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, onTaskCreation: { task in
			task?.resume()
			// See the download transport-failure variant.
			_ = delegateFired.wait(timeout: .now() + 2.0)
		}).then { _ in
			XCTFail("uploadFile should have failed")
			expectation.fulfill()
		}.catch { error in
			// See the download transport-failure variant for why we assert "not a CloudProviderError"
			// rather than equality against `URLProtocolMockError.simulatedTransportFailure`.
			XCTAssertNil(error as? CloudProviderError, "Transport failure was unexpectedly mapped: \(error)")
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 2.0)

		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// Verifies the load-bearing `PROPFIND`-skip behavior in `SignalingWebDAVClientURLSessionDelegate`.
	/// Without this guard, the regression tests above would silently turn into non-reproducers
	/// because the transfer's `onTaskCreation` wait would consume a stale `PROPFIND` signal before
	/// the registration race window opens.
	func testSignalingDelegateDoesNotSignalOnPropfindCompletion() throws {
		let (signalingProvider, delegateFired) = try makeSignalingProvider()
		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))

		let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
		let propfindResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
		URLProtocolMock.requestHandler.append({ request in
			guard let url = request.url, url.path == responseURL.path else {
				throw URLProtocolMockError.unexpectedRequest
			}
			return (propfindResponse, propfindData)
		})

		let expectation = expectation(description: "fetchItemMetadata resolves")
		signalingProvider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")).then { _ in
			expectation.fulfill()
		}.catch { error in
			XCTFail("fetchItemMetadata failed: \(error)")
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 2.0)

		XCTAssertEqual(.timedOut, delegateFired.wait(timeout: .now() + 0.1), "PROPFIND must not signal the semaphore")
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

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).async()) { error in
			XCTAssertEqual(.zero, self.client.propfindRequests["Documents/About.txt"])
			XCTAssertTrue(self.client.getRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
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

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL).async()) { error in
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

		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
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

		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).async()
		XCTAssertEqual(.zero, client.propfindRequests["Documents/About.txt"])
		XCTAssertTrue(client.putRequests.contains("Documents/About.txt"))
		XCTAssertEqual("About.txt", metadata.name)
		XCTAssertEqual("/Documents/About.txt", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT"), metadata.lastModifiedDate)
		XCTAssertEqual(1074, metadata.size)
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

		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true).async()
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
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true).async()) { error in
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

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).async()) { error in
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

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).async()) { error in
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

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true).async()) { error in
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
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false).async()) { error in
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

		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
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
		let responseURL = try XCTUnwrap(URL(string: "foo/", relativeTo: baseURL))

		let mkcolResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil))
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
		let responseURL = try XCTUnwrap(URL(string: "foo/", relativeTo: baseURL))

		let mkcolResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil))
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
		let responseURL = try XCTUnwrap(URL(string: "foo/", relativeTo: baseURL))

		let mkcolResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil))
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

		let responseURL = try XCTUnwrap(URL(string: "foo/", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.createFolder(at: CloudPath("/foo")).async()) { error in
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
		try await provider.deleteFile(at: CloudPath("/Documents/About.txt")).async()
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

		await XCTAssertThrowsErrorAsync(try await provider.deleteFile(at: CloudPath("/Documents/About.txt")).async()) { error in
			XCTAssertTrue(self.client.deleteRequests.contains("Documents/About.txt"))
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDeleteFileWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
		let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
		URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
		await XCTAssertThrowsErrorAsync(try await unauthorizedProvider.deleteFile(at: CloudPath("/Documents/About.txt")).async()) { error in
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

		try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).async()
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

		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).async()) { error in
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

		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).async()) { error in
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

		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")).async()) { error in
			XCTAssertEqual("Documents/Foobar.txt", self.client.moveRequests["Documents/About.txt"])
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testMoveFileWithUnauthorizedError() async throws {
		let unauthorizedClient = WebDAVClientMock(baseURL: baseURL, urlProtocolMock: URLProtocolAuthenticationMock.self)
		let unauthorizedProvider = try WebDAVProvider(with: unauthorizedClient)

		let responseURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let failureResponse = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
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

	private func makeSignalingProvider(urlProtocolMock: AnyClass = URLProtocolMock.self) throws -> (WebDAVProvider, DispatchSemaphore) {
		let signal = DispatchSemaphore(value: 0)
		let credential = WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil)
		let delegate = SignalingWebDAVClientURLSessionDelegate(credential: credential, signal: signal)
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [urlProtocolMock]
		let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		let client = WebDAVClient(credential: credential, session: WebDAVSession(urlSession: urlSession, delegate: delegate))
		let provider = try WebDAVProvider(with: client)
		return (provider, signal)
	}
}

/// Test-only delegate that signals a semaphore after the parent's transfer-task callback runs,
/// gating the caller's `onTaskCreation` closure on the delegate callback to make registration
/// races deterministic. Signaling is scoped to the transfer task of interest, never the preflight
/// `PROPFIND` — a leaked `PROPFIND` signal would be consumed by the transfer's `onTaskCreation`
/// wait and the race could never be reproduced. `URLSessionUploadTask` is a distinct subclass of
/// `URLSessionDataTask`, so plain `PROPFIND` data tasks do not match the upload checks below.
private final class SignalingWebDAVClientURLSessionDelegate: WebDAVClientURLSessionDelegate {
	let signal: DispatchSemaphore

	init(credential: WebDAVCredential, signal: DispatchSemaphore) {
		self.signal = signal
		super.init(credential: credential)
	}

	override func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		super.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
		// Signal the auth-rejection branch (`previousFailureCount >= 1`) for transfer tasks: the
		// parent delegate looks up the running task here to reject its promise — same race window.
		if challenge.previousFailureCount >= 1, task is URLSessionUploadTask || task is URLSessionDownloadTask {
			signal.signal()
		}
	}

	override func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		super.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
		signal.signal()
	}

	override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		super.urlSession(session, task: task, didCompleteWithError: error)
		// Signal successful upload completions (downloads use `didFinishDownloadingTo`) and transport
		// failures on either transfer task (auth rejections use `didReceive challenge:`).
		let isTransferTask = task is URLSessionUploadTask || task is URLSessionDownloadTask
		if task is URLSessionUploadTask, error == nil {
			signal.signal()
		} else if isTransferTask, error != nil {
			signal.signal()
		}
	}
}
