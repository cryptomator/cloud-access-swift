//
//  S3CloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 01.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class S3CloudProviderTests: XCTestCase {
	var provider: S3CloudProvider!
	var tmpDirURL: URL!

	override func setUpWithError() throws {
		provider = try S3CloudProvider(client: .mocked(), maxPageSize: .max)
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(provider)
	}

	func testCheckContinuationTokenForInvalidityWithCancelledRequest() async {
		let error = await provider.checkContinuationTokenForInvalidity(continuationToken: "token", folderPath: .root, error: CancellationError())
		XCTAssertTrue(error is CancellationError)
	}

	func testGetPrefix() {
		let rootCloudPath = CloudPath("/")
		XCTAssertEqual("", provider.getPrefix(for: rootCloudPath))

		XCTAssertEqual("foo/", provider.getPrefix(for: CloudPath("/foo")))
		XCTAssertEqual("foo/", provider.getPrefix(for: CloudPath("/foo/")))

		XCTAssertEqual("foo/bar/", provider.getPrefix(for: CloudPath("/foo/bar")))
	}

	func testGetKey() {
		XCTAssertEqual("foo.txt", provider.getKey(for: CloudPath("/foo.txt")))
		XCTAssertEqual("foo/bar.txt", provider.getKey(for: CloudPath("/foo/bar.txt")))
	}

	// MARK: - Error Conversion

	func testConvertStandardErrorPassesCancellationThrough() {
		XCTAssertTrue(provider.convertStandardError(CancellationError()) is CancellationError)
	}

	func testConvertUnauthorizedErrors() {
		for code in ["AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "InvalidSignatureException", "AuthFailure", "AccessDeniedException", "AuthMissingFailure", "InvalidClientTokenId", "MissingAuthenticationToken"] {
			XCTAssertEqual(.unauthorized, provider.convertStandardError(S3Error(statusCode: 403, code: code)) as? CloudProviderError, code)
		}
		XCTAssertEqual(.unauthorized, provider.convertStandardError(S3Error(statusCode: 401)) as? CloudProviderError)
		XCTAssertEqual(.unauthorized, provider.convertStandardError(S3Error(statusCode: 403)) as? CloudProviderError)
		XCTAssertEqual(.unauthorized, provider.convertStandardError(NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(CFNetworkErrors.cfErrorHTTPParseFailure.rawValue))) as? CloudProviderError)
	}

	func testConvertInvalidPageTokenErrors() {
		for code in ["ExpiredToken", "InvalidToken", "TokenRefreshRequired"] {
			XCTAssertEqual(.pageTokenInvalid, provider.convertStandardError(S3Error(statusCode: 400, code: code)) as? CloudProviderError, code)
		}
		XCTAssertEqual(.pageTokenInvalid, provider.convertStandardError(S3Error(statusCode: 400, code: "InvalidArgument", argumentName: "continuation-token")) as? CloudProviderError)
		XCTAssertEqual(.pageTokenInvalid, provider.convertStandardError(S3Error(statusCode: 500, code: "InternalError", reason: "Incorrect padding")) as? CloudProviderError)
	}

	func testConvertItemNotFoundError() {
		XCTAssertEqual(.itemNotFound, provider.convertStandardError(S3Error(statusCode: 404, code: "NoSuchKey")) as? CloudProviderError)
	}

	func testConvertNoInternetConnectionError() {
		XCTAssertEqual(.noInternetConnection, provider.convertStandardError(URLError(.notConnectedToInternet)) as? CloudProviderError)
	}

	func testConvertOtherErrorsUnchanged() {
		XCTAssertEqual(S3Error(statusCode: 400, code: "InvalidArgument", argumentName: "max-keys"), provider.convertStandardError(S3Error(statusCode: 400, code: "InvalidArgument", argumentName: "max-keys")) as? S3Error)
		XCTAssertEqual(S3Error(statusCode: 404, code: "NoSuchBucket"), provider.convertStandardError(S3Error(statusCode: 404, code: "NoSuchBucket")) as? S3Error)
		XCTAssertEqual(S3Error(statusCode: 404), provider.convertStandardError(S3Error(statusCode: 404)) as? S3Error)
	}

	// MARK: - Transfers

	func testDownloadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: S3CloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		let progress = Progress(totalUnitCount: 1)
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.txt"])),
			URLProtocolMock.handler(body: "content", onRequest: { _ in
				XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
			})
		]

		let metadata = try await value(of: Task {
			try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: progress, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		})

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: localURL))
		XCTAssertEqual(7, metadata.size)
		XCTAssertEqual(1, progress.fractionCompleted)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: S3CloudProvider = provider
		let localURL = try makeLocalFile()
		let progress = Progress(totalUnitCount: 1)
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			URLProtocolMock.handler(onRequest: { _ in
				XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
			}),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.txt"]), onRequest: { _ in
				XCTAssertGreaterThan(progress.fractionCompleted, 0.5, "The progress of the upload task isn't part of the upload's progress")
				XCTAssertLessThan(progress.fractionCompleted, 1, "The progress completed before the upload returned")
			})
		]

		let metadata = try await value(of: Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		})

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(CloudPath("/file.txt"), metadata.cloudPath)
		XCTAssertEqual(1, progress.fractionCompleted)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadFileWithCancellationDuringOnTaskCreation() async throws {
		let provider: S3CloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.txt"])),
			URLProtocolMock.handler(body: "content")
		]

		let download = Task {
			try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}

		XCTAssertEqual(1, URLProtocolMock.requestHandler.count, "The task of a cancelled download must not be resumed")
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testUploadFileWithCancellationDuringOnTaskCreation() async throws {
		let provider: S3CloudProvider = provider
		let localURL = try makeLocalFile()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			URLProtocolMock.handler()
		]

		let upload = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}

		XCTAssertEqual(1, URLProtocolMock.requestHandler.count, "The task of a cancelled upload must not be resumed")
	}

	/// The error body of a download may be missing, so any 404 means that the file is gone.
	func testDownloadFileOfMissingFileThrowsItemNotFound() async throws {
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.txt"])),
			URLProtocolMock.handler(statusCode: 404)
		]

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.itemNotFound, error as? CloudProviderError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	/// The upload committed with its PUT, so a cancellation afterwards must not cut short the retries of the metadata request.
	func testUploadFileCancelledAfterPutReturnsMetadata() async throws {
		let provider: S3CloudProvider = provider
		let localURL = try makeLocalFile()
		let upload = OSAllocatedUnfairLock<Task<CloudItemMetadata, Error>?>(initialState: nil)
		let uploadStored = DispatchSemaphore(value: 0)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []), onRequest: { _ in
				_ = uploadStored.wait(timeout: .now() + testWaitTimeout)
			}),
			URLProtocolMock.handler(onRequest: { _ in
				upload.withLock { $0 }?.cancel()
			}),
			URLProtocolMock.handler(statusCode: 503),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.txt"]))
		]

		let uploadTask = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
		}
		upload.withLock { $0 = uploadTask }
		uploadStored.signal()
		let metadata = try await value(of: uploadTask)

		XCTAssertEqual(CloudPath("/file.txt"), metadata.cloudPath)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	// MARK: - Requests

	func testFetchItemListRequestsOnePageOfFolder() async throws {
		let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/", "folder/a.txt"], commonPrefixes: ["folder/sub/"], nextContinuationToken: "next"), onRequest: { request in
				requests.withLock { $0.append(request) }
			})
		]

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: "token")

		let request = try XCTUnwrap(requests.withLock { $0 }.first)
		XCTAssertEqual("GET", request.httpMethod)
		XCTAssertEqual("/exampleBucket", request.url?.path)
		XCTAssertEqual(["list-type": "2", "prefix": "folder/", "max-keys": "1001", "delimiter": "/", "continuation-token": "token"], S3CloudProviderTests.queryParameters(of: request))
		XCTAssertEqual([CloudPath("/folder/a.txt"), CloudPath("/folder/sub")], itemList.items.map(\.cloudPath))
		XCTAssertEqual([.file, .folder], itemList.items.map(\.itemType))
		XCTAssertEqual("next", itemList.nextPageToken)
	}

	func testFetchItemListParsesLastModified() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/", "folder/a.txt"], lastModified: "2026-10-18T12:34:56.500Z"))
		]

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)

		XCTAssertEqual([Date(timeIntervalSince1970: 1_792_326_896.5)], itemList.items.map(\.lastModifiedDate))
	}

	func testFetchItemMetadataOfFolderListedAfterSibling() async throws {
		let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
		let recordRequest: @Sendable (URLRequest) -> Void = { request in
			requests.withLock { $0.append(request) }
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [], commonPrefixes: ["folder 2/"], nextContinuationToken: "next"), onRequest: recordRequest),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/"]), onRequest: recordRequest)
		]

		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/folder"))

		XCTAssertEqual(CloudPath("/folder"), metadata.cloudPath)
		XCTAssertEqual(.folder, metadata.itemType)
		XCTAssertEqual([
			["list-type": "2", "prefix": "folder", "max-keys": "1", "delimiter": "/"],
			["list-type": "2", "prefix": "folder/", "max-keys": "1", "delimiter": "/"]
		], requests.withLock { $0 }.map(S3CloudProviderTests.queryParameters(of:)))
	}

	func testFetchItemMetadataDoesNotListFolderAfterSiblingInCancelledTask() async throws {
		let provider: S3CloudProvider = provider
		let fetch = OSAllocatedUnfairLock<Task<CloudItemMetadata, Error>?>(initialState: nil)
		let fetchStored = DispatchSemaphore(value: 0)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [], commonPrefixes: ["folder 2/"], nextContinuationToken: "next"), onRequest: { _ in
				_ = fetchStored.wait(timeout: .now() + testWaitTimeout)
				fetch.withLock { $0 }?.cancel()
			}),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/"]))
		]

		let fetchTask = Task {
			try await provider.fetchItemMetadata(at: CloudPath("/folder"))
		}
		fetch.withLock { $0 = fetchTask }
		fetchStored.signal()

		await XCTAssertThrowsErrorAsync(try await value(of: fetchTask)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testFetchItemMetadataThrowsItemNotFoundIfOnlySiblingExists() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder.txt"], nextContinuationToken: "next")),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))
		]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/folder"))) { error in
			XCTAssertEqual(.itemNotFound, error as? CloudProviderError)
		}
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testCreateFolderPutsFolderMarker() async throws {
		let markerRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			URLProtocolMock.handler(onRequest: { request in
				markerRequest.withLock { $0 = request }
			})
		]

		try await provider.createFolder(at: CloudPath("/folder"))

		let request = try XCTUnwrap(markerRequest.withLock { $0 })
		XCTAssertEqual("PUT", request.httpMethod)
		XCTAssertEqual("/exampleBucket/folder/", request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath })
		XCTAssertEqual("application/x-directory", request.value(forHTTPHeaderField: "Content-Type"))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDeleteFolderDeletesEveryPage() async throws {
		let requests = OSAllocatedUnfairLock(initialState: [(request: URLRequest, body: String)]())
		let recordRequest: @Sendable (URLRequest) -> Void = { request in
			let body = String(bytes: URLProtocolMock.body(of: request), encoding: .utf8) ?? ""
			requests.withLock { $0.append((request, body)) }
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/"])),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/", "folder/a.txt"], nextContinuationToken: "next"), onRequest: recordRequest),
			URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: recordRequest),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/b.txt"]), onRequest: recordRequest),
			URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: recordRequest)
		]

		try await provider.deleteFolder(at: CloudPath("/folder"))

		let sent = requests.withLock { $0 }
		XCTAssertEqual(["GET", "POST", "GET", "POST"], sent.map(\.request.httpMethod))
		XCTAssertEqual(["list-type": "2", "prefix": "folder/", "max-keys": "1000"], S3CloudProviderTests.queryParameters(of: sent[0].request))
		XCTAssertEqual(["list-type": "2", "prefix": "folder/", "max-keys": "1000", "continuation-token": "next"], S3CloudProviderTests.queryParameters(of: sent[2].request))
		XCTAssertEqual(["delete": ""], S3CloudProviderTests.queryParameters(of: sent[1].request))
		XCTAssertTrue(sent[1].body.contains("<Object><Key>folder/</Key></Object><Object><Key>folder/a.txt</Key></Object>"), sent[1].body)
		XCTAssertTrue(sent[3].body.contains("<Object><Key>folder/b.txt</Key></Object>"), sent[3].body)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	// MARK: - Helpers

	private static func queryParameters(of request: URLRequest) -> [String: String] {
		let queryItems = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
		return Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
	}

	private func makeLocalFile() throws -> URL {
		let localURL = tmpDirURL.appendingPathComponent("local.txt")
		try Data("content".utf8).write(to: localURL)
		return localURL
	}
}

extension S3Credential {
	static let stub = S3Credential(accessKey: "access", secretKey: "secret", url: URL(string: "https://www.example.com")!, bucket: "exampleBucket", region: "example-region", identifier: UUID().uuidString)
}
