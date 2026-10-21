//
//  GoogleDriveCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 11.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class GoogleDriveCloudProviderTests: XCTestCase {
	private static let rootWithFile = GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "F", name: "file.txt")])
	private static let rootWithFolder = GoogleDriveMockResponse.files([GoogleDriveMockResponse.folder(id: "D", name: "folder")])
	private static let emptyFolder = GoogleDriveMockResponse.files([])

	private var provider: GoogleDriveCloudProvider!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		provider = try GoogleDriveCloudProvider(client: .mocked())
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

	// MARK: - Errors

	func testConvertStandardError() {
		let wrappedCancellationError = NSError(domain: "Test", code: 0, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)])
		XCTAssertTrue(provider.convertStandardError(wrappedCancellationError) is CancellationError)
		let cases: [(GoogleDriveError, CloudProviderError)] = [
			(.apiError(statusCode: 401, reason: nil, message: nil), .unauthorized),
			(.apiError(statusCode: 403, reason: "insufficientFilePermissions", message: nil), .unauthorized),
			(.apiError(statusCode: 403, reason: "storageQuotaExceeded", message: nil), .quotaInsufficient),
			(.apiError(statusCode: 404, reason: "notFound", message: nil), .itemNotFound),
			(.apiError(statusCode: 507, reason: nil, message: nil), .quotaInsufficient)
		]
		for (error, expectedError) in cases {
			XCTAssertEqual(expectedError, provider.convertStandardError(error) as? CloudProviderError, "\(error)")
		}
	}

	/// The client retried a rate limit until no attempt was left, which is no login failure.
	func testExceededRateLimitIsNotUnauthorized() {
		for reason in ["userRateLimitExceeded", "rateLimitExceeded"] {
			let error = GoogleDriveError.apiError(statusCode: 403, reason: reason, message: nil)

			XCTAssertEqual(error, provider.convertStandardError(error) as? GoogleDriveError, reason)
		}
	}

	func testFullDriveThrowsQuotaInsufficient() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
			URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "storageQuotaExceeded"))
		]

		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: CloudPath("/folder"))) { error in
			XCTAssertEqual(.quotaInsufficient, error as? CloudProviderError)
		}
	}

	// MARK: - Listings

	func testListingSkipsShortcutWhoseTargetIsGoneOrPrivate() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveMockResponse.files([
				GoogleDriveMockResponse.file(id: "F", name: "file.txt"),
				GoogleDriveMockResponse.shortcut(id: "S1", name: "broken", targetID: "T1", targetMimeType: "text/plain"),
				GoogleDriveMockResponse.shortcut(id: "S2", name: "private", targetID: "T2", targetMimeType: "text/plain"),
				GoogleDriveMockResponse.shortcut(id: "S3", name: "link", targetID: "T3", targetMimeType: "application/vnd.google-apps.folder")
			])),
			URLProtocolMock.handler(statusCode: 404, body: GoogleDriveMockResponse.error(status: 404, reason: "notFound")),
			URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "insufficientFilePermissions")),
			URLProtocolMock.handler(body: #"{"mimeType":"application/vnd.google-apps.folder","modifiedTime":"\#(GoogleDriveMockResponse.modifiedTime)"}"#)
		]

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

		XCTAssertEqual([
			CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: GoogleDriveDate.date(fromRFC3339: GoogleDriveMockResponse.modifiedTime), size: 7),
			CloudItemMetadata(name: "link", cloudPath: CloudPath("/link"), itemType: .folder, lastModifiedDate: GoogleDriveDate.date(fromRFC3339: GoogleDriveMockResponse.modifiedTime), size: nil)
		], itemList.items)
	}

	/// A shortcut whose target request fails on the connection or through every retry fails the listing, which would otherwise look complete without it.
	func testListingFailsIfShortcutTargetRequestFails() async throws {
		let cases = [
			ShortcutTargetFailureCase(name: "connection", response: { _ in throw URLError(.networkConnectionLost) }, expectedError: CloudProviderError.noInternetConnection),
			ShortcutTargetFailureCase(name: "rate limit", response: URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "rateLimitExceeded")), expectedError: GoogleDriveError.apiError(statusCode: 403, reason: "rateLimitExceeded", message: "Error"))
		]
		for testCase in cases {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.shortcut(id: "S1", name: "link", targetID: "T1", targetMimeType: "text/plain")]))
			] + Array(repeating: testCase.response, count: 5)

			await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil), testCase.name) { error in
				XCTAssertEqual(String(describing: testCase.expectedError), String(describing: error), testCase.name)
			}
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty, testCase.name)
		}
	}

	/// A 400 on the first page is a bad request, which a restart of the listing wouldn't heal.
	func testBadRequestIsPageTokenInvalidOnlyWithPageToken() async throws {
		let badRequest = URLProtocolMock.handler(statusCode: 400, body: GoogleDriveMockResponse.error(status: 400, reason: "invalid"))
		URLProtocolMock.requestHandler = [badRequest, badRequest]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)) { error in
			XCTAssertEqual(.apiError(statusCode: 400, reason: "invalid", message: "Error"), error as? GoogleDriveError)
		}
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "TOKEN")) { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}
	}

	// MARK: - Shortcuts

	/// Requests for a shortcut's content and children go to its target, whereas a move or delete changes the shortcut itself.
	func testShortcutRequestsUseTargetOnlyForContent() async throws {
		let requests = RequestRecorder()
		let record = requests.record
		let folderShortcut = GoogleDriveMockResponse.shortcut(id: "S1", name: "folder", targetID: "T1", targetMimeType: GoogleDriveJSON.folderMimeType)
		let fileShortcut = GoogleDriveMockResponse.shortcut(id: "S2", name: "link.txt", targetID: "T2", targetMimeType: "text/plain")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveMockResponse.files([folderShortcut]), onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "T1", name: "target"), onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder, onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder, onRequest: record),
			GoogleDriveMockResponse.session(onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12), onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.files([fileShortcut]), onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "T2", name: "target.txt"), onRequest: record),
			URLProtocolMock.handler(body: "content", onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder, onRequest: record),
			URLProtocolMock.handler(body: fileShortcut, onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder, onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "N", name: "new"), onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder, onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "moved.txt", size: 12), onRequest: record),
			URLProtocolMock.handler(statusCode: 204, onRequest: record)
		]

		_ = try await provider.fetchItemMetadata(at: CloudPath("/folder"))
		_ = try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)
		_ = try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/folder/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
		_ = try await provider.downloadFile(from: CloudPath("/link.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)
		try await provider.moveFile(from: CloudPath("/link.txt"), to: CloudPath("/folder/link.txt"))
		try await provider.createFolder(at: CloudPath("/folder/new"))
		try await provider.moveFile(from: CloudPath("/folder/file.txt"), to: CloudPath("/moved.txt"))
		try await provider.deleteFolder(at: CloudPath("/folder"))

		let sent = requests.requests
		XCTAssertEqual(16, sent.count)
		XCTAssertEqual("/drive/v3/files/T1", sent[1].url?.path)
		XCTAssertEqual("'T1' in parents and trashed = false", GoogleDriveCloudProviderTests.queryParameter("q", of: sent[2]))
		XCTAssertEqual("'T1' in parents and name contains 'file.txt' and trashed = false", GoogleDriveCloudProviderTests.queryParameter("q", of: sent[3]))
		XCTAssertEqual(["name": "file.txt", "parents": ["T1"]] as NSDictionary, try JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[4])) as? NSDictionary)
		XCTAssertEqual("/drive/v3/files/T2", sent[7].url?.path)
		XCTAssertEqual("/download/drive/v3/files/T2", sent[8].url?.path)
		XCTAssertEqual(["PATCH", "/drive/v3/files/S2", "T1", "root"], [sent[10].httpMethod, sent[10].url?.path, GoogleDriveCloudProviderTests.queryParameter("addParents", of: sent[10]), GoogleDriveCloudProviderTests.queryParameter("removeParents", of: sent[10])])
		XCTAssertEqual(["name": "new", "parents": ["T1"], "mimeType": GoogleDriveJSON.folderMimeType] as NSDictionary, try JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[12])) as? NSDictionary)
		XCTAssertEqual(["/drive/v3/files/F", "root", "T1"], [sent[14].url?.path, GoogleDriveCloudProviderTests.queryParameter("addParents", of: sent[14]), GoogleDriveCloudProviderTests.queryParameter("removeParents", of: sent[14])])
		XCTAssertEqual(["DELETE", "/drive/v3/files/S1"], [sent[15].httpMethod, sent[15].url?.path])
	}

	/// Replacing a shortcut writes the content to its target, and the path stays the shortcut, so that deleting it afterwards deletes only the shortcut.
	func testReplacingShortcutWritesToTargetAndKeepsShortcut() async throws {
		let requests = RequestRecorder()
		let record = requests.record
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.shortcut(id: "S", name: "link.txt", targetID: "T", targetMimeType: "text/plain")]), onRequest: record),
			GoogleDriveMockResponse.session(onRequest: record),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "T", name: "target.txt", size: 12), onRequest: record),
			URLProtocolMock.handler(statusCode: 204, onRequest: record)
		]

		_ = try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/link.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil)
		try await provider.deleteFile(at: CloudPath("/link.txt"))

		let sent = requests.requests
		XCTAssertEqual(4, sent.count)
		XCTAssertEqual(["PATCH", "/upload/drive/v3/files/T"], [sent[1].httpMethod, sent[1].url?.path])
		XCTAssertEqual([:] as NSDictionary, try JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[1])) as? NSDictionary)
		XCTAssertEqual(["DELETE", "/drive/v3/files/S"], [sent[3].httpMethod, sent[3].url?.path])
	}

	func testReplacingShortcutToFolderThrowsItemAlreadyExists() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.shortcut(id: "S", name: "folder", targetID: "T", targetMimeType: GoogleDriveJSON.folderMimeType)]))
		]

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/folder"), replaceExisting: true, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.itemAlreadyExists, error as? CloudProviderError)
		}
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	// MARK: - Moves

	/// A move stores the type of the moved item, so that the provider can download it afterwards.
	func testMovedFileCanBeDownloaded() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFile),
			{ request in
				// Answers with the requested fields only, as Drive does.
				let fields = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "fields" }?.value } ?? ""
				let file: [String: String] = ["id": "F", "name": "renamed.txt", "mimeType": "text/plain", "modifiedTime": GoogleDriveMockResponse.modifiedTime].filter { fields.split(separator: ",").contains(Substring($0.key)) }
				return try URLProtocolMock.handler(body: String(bytes: JSONSerialization.data(withJSONObject: file), encoding: .utf8) ?? "")(request)
			},
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "renamed.txt")),
			URLProtocolMock.handler(body: "content")
		]

		try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))
		let metadata = try await provider.downloadFile(from: CloudPath("/renamed.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)

		XCTAssertEqual(7, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	// MARK: - Transfers

	func testDownloadAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: GoogleDriveCloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", onRequest: { _ in
			XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
		})]

		let metadata = try await value(of: Task {
			try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		})

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: localURL))
		XCTAssertEqual(7, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: GoogleDriveCloudProvider = provider
		let localURL = try makeLocalFile(content: "file content")
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
			GoogleDriveMockResponse.session(),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12), onRequest: { _ in
				XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
			})
		]

		let metadata = try await value(of: Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		})

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: GoogleDriveDate.date(fromRFC3339: GoogleDriveMockResponse.modifiedTime), size: 12), metadata)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadWithCancellationDuringOnTaskCreation() async throws {
		let provider: GoogleDriveCloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content")]

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

	func testUploadWithCancellationDuringOnTaskCreation() async throws {
		let provider: GoogleDriveCloudProvider = provider
		let localURL = try makeLocalFile(content: "file content")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
			GoogleDriveMockResponse.session(),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))
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

	func testFailedDownloadThrowsItsErrorAndLeavesNoFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent("download.txt")
		URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(statusCode: 404, body: GoogleDriveMockResponse.error(status: 404, reason: "notFound"))]

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.itemNotFound, error as? CloudProviderError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testDownloadReportsBytesOfTask() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try GoogleDriveCloudProvider(client: .mocked(hooks: PCloudProviderTestResponse.recordingTransferProgress(of: progress, into: fractions)))
		URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

		assertTransferProgress(fractions.withLock { $0 })
	}

	func testUploadReportsBytesOfTask() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try GoogleDriveCloudProvider(client: .mocked(hooks: PCloudProviderTestResponse.recordingTransferProgress(of: progress, into: fractions)))
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
			GoogleDriveMockResponse.session(),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))
		]

		_ = try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

		assertTransferProgress(fractions.withLock { $0 })
	}

	/// Each attempt adds the progress of its task, so a retry takes half of the transfer's share instead of pushing it past complete.
	func testRetriedDownloadSharesProgressWithFirstAttempt() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let fractionAtRetry = OSAllocatedUnfairLock<Double?>(initialState: nil)
		let provider = try GoogleDriveCloudProvider(client: .mocked(hooks: PCloudProviderTestResponse.recordingTransferProgress(of: progress, into: fractions)))
		URLProtocolMock.requestHandler = downloadPreparation() + [
			URLProtocolMock.handler(statusCode: 503, body: "BACKEND", headerFields: ["Content-Length": "7"]),
			URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"], onRequest: { _ in
				fractionAtRetry.withLock { $0 = progress.fractionCompleted }
			})
		]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

		try assertRetryHalvesProgress(fractions.withLock { $0 }, fractionAtRetry: fractionAtRetry.withLock { $0 })
	}

	func testPutSentAgainSharesProgressWithFirstOne() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let fractionAtRetry = OSAllocatedUnfairLock<Double?>(initialState: nil)
		let provider = try GoogleDriveCloudProvider(client: .mocked(hooks: PCloudProviderTestResponse.recordingTransferProgress(of: progress, into: fractions)))
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
			GoogleDriveMockResponse.session(),
			URLProtocolMock.handler(statusCode: 503),
			URLProtocolMock.handler(statusCode: 308),
			URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12), onRequest: { _ in
				fractionAtRetry.withLock { $0 = progress.fractionCompleted }
			})
		]

		_ = try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

		try assertRetryHalvesProgress(fractions.withLock { $0 }, fractionAtRetry: fractionAtRetry.withLock { $0 })
	}

	// MARK: - Cancellation

	/// A mutation's request is its commit point, so it runs with its retries also if the task is cancelled during the first attempt.
	func testCancelledMutationsStillFinishTheirRequests() async throws {
		let cases = [
			GoogleDriveMutationCase(name: "create folder", preparation: [URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder)], success: URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "D", name: "folder"))) { provider in
				try await provider.createFolder(at: CloudPath("/folder"))
			},
			GoogleDriveMutationCase(name: "delete file", preparation: [URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFile)], success: URLProtocolMock.handler(statusCode: 204)) { provider in
				try await provider.deleteFile(at: CloudPath("/file.txt"))
			},
			GoogleDriveMutationCase(name: "delete folder", preparation: [URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFolder)], success: URLProtocolMock.handler(statusCode: 204)) { provider in
				try await provider.deleteFolder(at: CloudPath("/folder"))
			},
			GoogleDriveMutationCase(name: "move file", preparation: [URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder), URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFile)], success: URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "renamed.txt"))) { provider in
				try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))
			},
			GoogleDriveMutationCase(name: "move folder", preparation: [URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder), URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFolder)], success: URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "D", name: "renamed"))) { provider in
				try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed"))
			}
		]
		for mutationCase in cases {
			let provider = try GoogleDriveCloudProvider(client: .mocked())
			let mutation = OSAllocatedUnfairLock<Task<Void, Error>?>(initialState: nil)
			let started = XCTestExpectation(description: "\(mutationCase.name) started")
			URLProtocolMock.requestHandler = mutationCase.preparation + [
				URLProtocolMock.handler(statusCode: 503, onRequest: { _ in
					mutation.withLock { $0 }?.cancel()
				}),
				mutationCase.success
			]

			let task = Task {
				_ = await XCTWaiter().fulfillment(of: [started], timeout: testWaitTimeout)
				try await mutationCase.operation(provider)
			}
			mutation.withLock { $0 = task }
			started.fulfill()

			try await value(of: task)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty, mutationCase.name)
		}
	}

	/// A cancellation while a shortcut's target request is retried ends the listing.
	func testCancellationDuringShortcutResolutionEndsListing() async throws {
		let provider: GoogleDriveCloudProvider = provider
		let listing = OSAllocatedUnfairLock<Task<CloudItemList, Error>?>(initialState: nil)
		let started = XCTestExpectation(description: "listing started")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: GoogleDriveMockResponse.files([
				GoogleDriveMockResponse.shortcut(id: "S1", name: "link", targetID: "T1", targetMimeType: "text/plain"),
				GoogleDriveMockResponse.file(id: "F", name: "file.txt")
			])),
			URLProtocolMock.handler(statusCode: 503, onRequest: { _ in
				listing.withLock { $0 }?.cancel()
			}),
			URLProtocolMock.handler(body: #"{"mimeType":"text/plain","modifiedTime":"\#(GoogleDriveMockResponse.modifiedTime)"}"#)
		]

		let task = Task {
			_ = await XCTWaiter().fulfillment(of: [started], timeout: testWaitTimeout)
			return try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		}
		listing.withLock { $0 = task }
		started.fulfill()

		await XCTAssertThrowsErrorAsync(try await value(of: task)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
	}

	// MARK: - Paths

	func testOnlyItemNameChangedWorksWithFolders() {
		let oldCloudPath = CloudPath("/AAAAAA/BBBBBBB")
		let newCloudPathOnlyFolderNameChanged = CloudPath("/AAAAAA/CCCCCCC")
		XCTAssertTrue(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathOnlyFolderNameChanged))

		let newCloudPathWithParentFolderChanged = CloudPath("/DDDDDDD/BBBBBBB")
		XCTAssertFalse(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathWithParentFolderChanged))

		let newCloudPathParentFolderAndFolderNameChanged = CloudPath("/DDDDDDD/CCCCCCC")
		XCTAssertFalse(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathParentFolderAndFolderNameChanged))
	}

	func testOnlyItemNameChangedWorksWithFiles() {
		let oldCloudPath = CloudPath("/AAAAAA/test.txt")
		let newCloudPathOnlyFileNameChanged = CloudPath("/AAAAAA/renamedTest.txt")
		XCTAssertTrue(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathOnlyFileNameChanged))

		let newCloudPathWithChangedPath = CloudPath("/DDDDDDD/BBBBBBB/test.txt")
		XCTAssertFalse(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathWithChangedPath))

		let newCloudPathWithPathAndFileNameChanged = CloudPath("/DDDDDDD/CCCCCCC/renamedAgainTest.txt")
		XCTAssertFalse(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathWithPathAndFileNameChanged))
	}

	// MARK: - Helpers

	/// The responses of the name lookup and the metadata request of `/file.txt`, before its download.
	private func downloadPreparation() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
		return [URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFile), URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt"))]
	}

	private func makeLocalFile(content: String) throws -> URL {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		try Data(content.utf8).write(to: localURL)
		return localURL
	}

	private func assertRetryHalvesProgress(_ fractions: [Double], fractionAtRetry: Double?, file: StaticString = #filePath, line: UInt = #line) throws {
		XCTAssertEqual(2, fractions.count, "Unexpected number of transfer tasks", file: file, line: line)
		let fractionAfterFirstAttempt = try XCTUnwrap(fractions.first, file: file, line: line)
		XCTAssertGreaterThan(fractionAfterFirstAttempt, 0.5, file: file, line: line)
		XCTAssertEqual(fractionAfterFirstAttempt / 2, try XCTUnwrap(fractionAtRetry, file: file, line: line), accuracy: 0.01, file: file, line: line)
		XCTAssertEqual(fractionAfterFirstAttempt, try XCTUnwrap(fractions.last, file: file, line: line), accuracy: 0.01, file: file, line: line)
	}

	private static func queryParameter(_ name: String, of request: URLRequest) -> String? {
		return request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
	}

	private func assertTransferProgress(_ fractions: [Double], file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertEqual(1, fractions.count, "Unexpected number of transfer tasks", file: file, line: line)
		XCTAssertGreaterThan(fractions.first ?? 0, 0.5, "The progress of the transfer task isn't part of the transfer's progress", file: file, line: line)
		XCTAssertLessThan(fractions.first ?? 1, 1, "The progress completed before the transfer returned", file: file, line: line)
	}
}

private struct GoogleDriveMutationCase {
	let name: String
	/// The responses to the requests before the mutation's request.
	let preparation: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)]
	/// The response to the retry of the mutation's request.
	let success: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let operation: @Sendable (GoogleDriveCloudProvider) async throws -> Void
}

private struct ShortcutTargetFailureCase {
	let name: String
	let response: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let expectedError: Error
}
