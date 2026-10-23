//
//  DropboxCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DropboxCloudProviderTests: XCTestCase {
	private static let uploadSessionStart = #"{"session_id":"SESSION"}"#

	private var provider: DropboxCloudProvider!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max)
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

	// MARK: - Metadata and Listings

	func testFetchItemMetadataOfFileAndFolder() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt")),
			URLProtocolMock.handler(body: DropboxMockResponse.folder(name: "folder"))
		]

		let file = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))
		let folder = try await provider.fetchItemMetadata(at: CloudPath("/folder"))

		XCTAssertEqual(CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: DropboxDate.date(from: DropboxMockResponse.serverModified), size: 7), file)
		XCTAssertEqual(CloudItemMetadata(name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, lastModifiedDate: nil, size: nil), folder)
	}

	func testFetchItemListConvertsEntriesAndReturnsCursorOnlyIfMore() async throws {
		let log = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxMockResponse.listing([DropboxMockResponse.file(name: "file.txt"), DropboxMockResponse.folder(name: "folder")], cursor: "NEXT", hasMore: true), onRequest: log.record),
			URLProtocolMock.handler(body: DropboxMockResponse.listing([], cursor: "LAST"), onRequest: log.record)
		]

		let firstPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		let lastPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "NEXT")

		XCTAssertEqual([CloudPath("/file.txt"), CloudPath("/folder")], firstPage.items.map(\.cloudPath))
		XCTAssertEqual([.file, .folder], firstPage.items.map(\.itemType))
		XCTAssertEqual("NEXT", firstPage.nextPageToken)
		XCTAssertTrue(lastPage.items.isEmpty)
		XCTAssertNil(lastPage.nextPageToken)
		let firstArgument = try XCTUnwrap(log.requests.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
		XCTAssertEqual("", firstArgument["path"] as? String)
		XCTAssertEqual(2000, firstArgument["limit"] as? Int)
	}

	func testUntaggedListingEntryThrows() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxMockResponse.listing([DropboxMockResponse.file(name: "file.txt", tagged: false)]))]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)) { error in
			XCTAssertEqual(.unexpectedContent, error as? DropboxError)
		}
	}

	func testMalformedCursorIsPageTokenInvalid() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400, body: "Error in call to API function \"files/list_folder/continue\": Invalid \"cursor\" parameter")]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "invalidPageToken")) { error in
			XCTAssertEqual(.pageTokenInvalid, error as? CloudProviderError)
		}
	}

	// MARK: - Errors

	func testRouteErrorsAreConverted() async throws {
		let localURL = try makeLocalFile(content: "content")
		let localTargetURL = tmpDirURL.appendingPathComponent("download.txt")
		let cases: [ErrorCase] = [
			ErrorCase(summary: "path/not_found/..", expectedError: CloudProviderError.itemNotFound) { _ = try await $0.fetchItemMetadata(at: CloudPath("/missing")) },
			ErrorCase(summary: "path/not_folder/..", expectedError: CloudProviderError.itemTypeMismatch) { _ = try await $0.fetchItemList(forFolderAt: CloudPath("/file.txt"), withPageToken: nil) },
			ErrorCase(summary: "reset/..", expectedError: CloudProviderError.pageTokenInvalid) { _ = try await $0.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "OLD") },
			ErrorCase(summary: "path/not_file/..", expectedError: CloudProviderError.itemTypeMismatch) { _ = try await $0.downloadFile(from: CloudPath("/folder"), to: localTargetURL, progress: nil, onTaskCreation: nil) },
			ErrorCase(summary: "path/conflict/file/..", expectedError: CloudProviderError.itemAlreadyExists) { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) },
			ErrorCase(summary: "path/insufficient_space/..", expectedError: CloudProviderError.quotaInsufficient) { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil) },
			ErrorCase(summary: "path/conflict/folder/..", expectedError: CloudProviderError.itemAlreadyExists) { try await $0.createFolder(at: CloudPath("/folder")) },
			ErrorCase(summary: "path/insufficient_space/..", expectedError: CloudProviderError.quotaInsufficient) { try await $0.createFolder(at: CloudPath("/folder")) },
			ErrorCase(summary: "path_lookup/not_found/..", expectedError: CloudProviderError.itemNotFound) { try await $0.deleteFile(at: CloudPath("/file.txt")) },
			ErrorCase(summary: "path_write/conflict/..", expectedError: CloudProviderError.itemAlreadyExists) { try await $0.deleteFolder(at: CloudPath("/folder")) },
			ErrorCase(summary: "path_write/insufficient_space/..", expectedError: CloudProviderError.quotaInsufficient) { try await $0.deleteFile(at: CloudPath("/file.txt")) },
			ErrorCase(summary: "from_lookup/not_found/..", expectedError: CloudProviderError.itemNotFound) { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) },
			ErrorCase(summary: "from_lookup/not_folder/..", expectedError: CloudProviderError.itemTypeMismatch) { try await $0.moveFolder(from: CloudPath("/file.txt"), to: CloudPath("/renamed")) },
			ErrorCase(summary: "from_write/conflict/..", expectedError: CloudProviderError.itemAlreadyExists) { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) },
			ErrorCase(summary: "to/conflict/file/..", expectedError: CloudProviderError.itemAlreadyExists) { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) },
			ErrorCase(summary: "to/insufficient_space/..", expectedError: CloudProviderError.quotaInsufficient) { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) },
			ErrorCase(summary: "insufficient_quota/..", expectedError: CloudProviderError.quotaInsufficient) { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) },
			ErrorCase(summary: "path/malformed_path/..", expectedError: DropboxError.apiError(statusCode: 409, summary: "path/malformed_path/..")) { _ = try await $0.fetchItemMetadata(at: CloudPath("/file.txt")) }
		]
		for errorCase in cases {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 409, body: DropboxMockResponse.error(errorCase.summary))]

			await XCTAssertThrowsErrorAsync(try await errorCase.operation(provider), errorCase.summary) { error in
				XCTAssertEqual(String(describing: errorCase.expectedError), String(describing: error), errorCase.summary)
			}
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty, errorCase.summary)
		}
	}

	func testRejectedTokenIsUnauthorized() async throws {
		URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 401, body: DropboxMockResponse.error("invalid_access_token/..")), count: 2)

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
	}

	func testMissingParentFolderThrowsWithoutWriting() async throws {
		let localURL = try makeLocalFile(content: "content")
		let operations: [(name: String, operation: @Sendable (DropboxCloudProvider) async throws -> Void)] = [
			("upload", { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/missing/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }),
			("create folder", { try await $0.createFolder(at: CloudPath("/missing/folder")) }),
			("move", { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/missing/file.txt")) })
		]
		for (name, operation) in operations {
			let log = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 409, body: DropboxMockResponse.error("path/not_found/.."), onRequest: log.record),
				URLProtocolMock.handler(body: "{}", onRequest: log.record)
			]

			await XCTAssertThrowsErrorAsync(try await operation(provider), name) { error in
				XCTAssertEqual(.parentFolderDoesNotExist, error as? CloudProviderError, name)
			}
			XCTAssertEqual(["/2/files/get_metadata"], log.requests.map { $0.url?.path }, name)
		}
	}

	func testCancelledMutationsStillFinishTheirRequests() async throws {
		let operations: [(name: String, operation: @Sendable (DropboxCloudProvider) async throws -> Void)] = [
			("create folder", { try await $0.createFolder(at: CloudPath("/folder")) }),
			("delete file", { try await $0.deleteFile(at: CloudPath("/file.txt")) }),
			("delete folder", { try await $0.deleteFolder(at: CloudPath("/folder")) }),
			("move file", { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) }),
			("move folder", { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) })
		]
		for (name, operation) in operations {
			let provider: DropboxCloudProvider = provider
			let mutation = OSAllocatedUnfairLock<Task<Void, Error>?>(initialState: nil)
			let started = XCTestExpectation(description: "\(name) started")
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 503, onRequest: { _ in
					mutation.withLock { $0 }?.cancel()
				}),
				URLProtocolMock.handler(body: "{}")
			]

			let task = Task {
				_ = await XCTWaiter().fulfillment(of: [started], timeout: testWaitTimeout)
				try await operation(provider)
			}
			mutation.withLock { $0 = task }
			started.fulfill()

			try await value(of: task)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty, name)
		}
	}

	// MARK: - Transfers

	func testDownloadAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: DropboxCloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "content", headerFields: ["Dropbox-API-Result": DropboxMockResponse.file(name: "file.txt", tagged: false)], onRequest: { _ in
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
		XCTAssertEqual(CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: DropboxDate.date(from: DropboxMockResponse.serverModified), size: 7), metadata)
	}

	func testUploadAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: DropboxCloudProvider = provider
		let localURL = try makeLocalFile(content: "content")
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", tagged: false), onRequest: { _ in
			XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
		})]

		let metadata = try await value(of: Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		})

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: DropboxDate.date(from: DropboxMockResponse.serverModified), size: 7), metadata)
	}

	func testCancellationDuringOnTaskCreationSendsNoTransfer() async throws {
		let provider: DropboxCloudProvider = provider
		let localURL = try makeLocalFile(content: "content")
		let downloadURL = tmpDirURL.appendingPathComponent("download.txt")
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "content")]

		await XCTAssertThrowsErrorAsync(try await value(of: Task {
			try await provider.downloadFile(from: CloudPath("/file.txt"), to: downloadURL, progress: nil, onTaskCreation: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			})
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		await XCTAssertThrowsErrorAsync(try await value(of: Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			})
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertFalse(FileManager.default.fileExists(atPath: downloadURL.path))
	}

	func testTransfersReportBytesOfTask() async throws {
		let localURL = try makeLocalFile(content: "content")
		let downloadURL = tmpDirURL.appendingPathComponent("download.txt")
		let transfers = [
			TransferCase(name: "download", response: URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7", "Dropbox-API-Result": DropboxMockResponse.file(name: "file.txt", tagged: false)])) { provider, progress in
				_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: downloadURL, progress: progress, onTaskCreation: nil)
			},
			TransferCase(name: "upload", response: URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", tagged: false))) { provider, progress in
				_ = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)
			}
		]
		for transfer in transfers {
			let name = transfer.name
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = DropboxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max)
			URLProtocolMock.requestHandler = [transfer.response]

			try await transfer.operation(provider, progress)

			let recordedFractions = fractions.withLock { $0 }
			XCTAssertEqual(1, recordedFractions.count, name)
			XCTAssertGreaterThan(recordedFractions.first ?? 0, 0.5, name)
			XCTAssertLessThan(recordedFractions.first ?? 1, 1, name)
		}
	}

	/// Each attempt adds the progress of its task, so a retry takes half of the transfer's share instead of pushing it past complete.
	func testRetriedDownloadSharesProgressWithFirstAttempt() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let fractionAtRetry = OSAllocatedUnfairLock<Double?>(initialState: nil)
		let provider = DropboxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 503, body: "content", headerFields: ["Content-Length": "7"]),
			URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7", "Dropbox-API-Result": DropboxMockResponse.file(name: "file.txt", tagged: false)], onRequest: { _ in
				fractionAtRetry.withLock { $0 = progress.fractionCompleted }
			})
		]

		_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

		let recordedFractions = fractions.withLock { $0 }
		XCTAssertEqual(2, recordedFractions.count)
		let fractionAfterFirstAttempt = try XCTUnwrap(recordedFractions.first)
		XCTAssertGreaterThan(fractionAfterFirstAttempt, 0.5)
		XCTAssertEqual(fractionAfterFirstAttempt / 2, try XCTUnwrap(fractionAtRetry.withLock { $0 }), accuracy: 0.01)
		XCTAssertEqual(fractionAfterFirstAttempt, try XCTUnwrap(recordedFractions.last), accuracy: 0.01)
	}

	func testUploadModeFollowsReplaceExisting() async throws {
		let localURL = try makeLocalFile(content: "content")
		let largeLocalURL = try makeLocalFile(content: "0123456789")
		let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 16)
		for (replaceExisting, expectedMode) in [(false, "add"), (true, "overwrite")] {
			let recorder = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", tagged: false), onRequest: recorder.record),
				URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart),
				URLProtocolMock.handler(body: "null"),
				URLProtocolMock.handler(body: DropboxMockResponse.file(name: "large.txt", size: 10, tagged: false), onRequest: recorder.record)
			]

			_ = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: replaceExisting, progress: nil, onTaskCreation: nil)
			_ = try await provider.uploadFile(from: largeLocalURL, to: CloudPath("/large.txt"), replaceExisting: replaceExisting, progress: nil, onTaskCreation: nil)

			let requests = recorder.requests
			XCTAssertEqual(["/2/files/upload", "/2/files/upload_session/finish"], requests.map { $0.url?.path })
			XCTAssertEqual(expectedMode, try XCTUnwrap(requests.first.flatMap(DropboxCloudProviderTests.argument))["mode"] as? String)
			XCTAssertEqual(expectedMode, try (XCTUnwrap(requests.last.flatMap(DropboxCloudProviderTests.argument))["commit"] as? [String: Any])?["mode"] as? String)
		}
	}

	// MARK: - Upload Sessions

	func testLargeUploadAppendsChunksFromFilesAndFinishes() async throws {
		let appendTasks = OSAllocatedUnfairLock(initialState: [(isUploadTask: Bool, hasBody: Bool)]())
		let hooks = SplitURLSession.Hooks(willProcessCompletion: { task in
			if task.originalRequest?.url?.path == "/2/files/upload_session/append_v2" {
				appendTasks.withLock { $0.append((task is URLSessionUploadTask, task.originalRequest?.httpBody != nil)) }
			}
		})
		let provider = DropboxCloudProvider(client: .mocked(hooks: hooks), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
		let localURL = try makeLocalFile(content: "0123456789")
		let temporaryFiles = try uuidNamedTemporaryFiles()
		let log = RequestRecorder()
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart, onRequest: log.record)]
			+ Array(repeating: URLProtocolMock.handler(body: "null", onRequest: log.record), count: 3)
			+ [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false), onRequest: log.record)]

		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

		XCTAssertEqual(10, metadata.size)
		XCTAssertEqual(temporaryFiles, try uuidNamedTemporaryFiles())
		let requests = log.requests
		XCTAssertEqual(["start", "append_v2", "append_v2", "append_v2", "finish"], requests.map { $0.url?.lastPathComponent })
		XCTAssertEqual([0, 4, 8], try requests[1 ... 3].map(DropboxCloudProviderTests.appendOffset))
		XCTAssertEqual(["0123", "4567", "89"], requests[1 ... 3].map { String(bytes: $0.httpBody ?? Data(), encoding: .utf8) })
		let finishArgument = try XCTUnwrap(DropboxCloudProviderTests.argument(of: requests[4]))
		XCTAssertEqual(10, (finishArgument["cursor"] as? [String: Any])?["offset"] as? Int)
		XCTAssertEqual("/file.txt", (finishArgument["commit"] as? [String: Any])?["path"] as? String)
		let tasks = appendTasks.withLock { $0 }
		XCTAssertEqual(3, tasks.count)
		XCTAssertTrue(tasks.allSatisfy { $0.isUploadTask && !$0.hasBody })
	}

	func testIncorrectOffsetContinuesFromCorrectOffset() async throws {
		let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
		let log = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart),
			URLProtocolMock.handler(statusCode: 409, body: DropboxCloudProviderTests.incorrectOffset(8), onRequest: log.record),
			URLProtocolMock.handler(body: "null", onRequest: log.record),
			URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false))
		]

		_ = try await provider.uploadFile(from: makeLocalFile(content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

		XCTAssertEqual([0, 8], try log.requests.map(DropboxCloudProviderTests.appendOffset))
		XCTAssertEqual(["0123", "89"], log.requests.map { String(bytes: $0.httpBody ?? Data(), encoding: .utf8) })
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	/// Each append's response is lost, so its repeat is answered with the offset after the chunk.
	func testLostAppendResponsesComplete() async throws {
		let sleeps = SleepRecorder()
		let provider = DropboxCloudProvider(client: .mocked(sleeps: sleeps), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
		let lostResponse: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) = { _ in
			throw URLError(.networkConnectionLost)
		}
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart)]
			+ [4, 8, 12, 16].flatMap { correctOffset in
				[lostResponse, URLProtocolMock.handler(statusCode: 409, body: DropboxCloudProviderTests.incorrectOffset(correctOffset))]
			}
			+ [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 16, tagged: false))]

		let metadata = try await provider.uploadFile(from: makeLocalFile(content: "0123456789ABCDEF"), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

		XCTAssertEqual(16, metadata.size)
		XCTAssertEqual(4, sleeps.durations.count)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadGivesUpWhenDropboxStopsConfirmingProgress() async throws {
		let accepted = URLProtocolMock.handler(body: "null")
		let rewound = URLProtocolMock.handler(statusCode: 409, body: DropboxCloudProviderTests.incorrectOffset(0))
		let cases: [(name: String, appends: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)])] = [
			("stuck", Array(repeating: rewound, count: 4)),
			("rewinding every third request", Array(repeating: [accepted, accepted, rewound], count: 4).flatMap(\.self))
		]
		for (name, appends) in cases {
			let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
			let localURL = try makeLocalFile(content: "0123456789ABCDEF")
			let temporaryFiles = try uuidNamedTemporaryFiles()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart)] + appends + [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 16, tagged: false))]

			await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil), name) { error in
				XCTAssertEqual(.unexpectedContent, error as? DropboxError, name)
			}
			XCTAssertEqual(1, URLProtocolMock.requestHandler.count, name)
			XCTAssertEqual(temporaryFiles, try uuidNamedTemporaryFiles(), name)
		}
	}

	func testCorrectOffsetOutsideFileThrows() async throws {
		for correctOffset in [-1, 17] {
			let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart),
				URLProtocolMock.handler(statusCode: 409, body: DropboxCloudProviderTests.incorrectOffset(correctOffset)),
				URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 16, tagged: false))
			]

			await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: makeLocalFile(content: "0123456789ABCDEF"), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil), "\(correctOffset)") { error in
				XCTAssertEqual(.unexpectedContent, error as? DropboxError, "\(correctOffset)")
			}
			XCTAssertEqual(1, URLProtocolMock.requestHandler.count, "\(correctOffset)")
		}
	}

	func testFileThatGetsShorterDuringUploadThrows() async throws {
		let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
		let localURL = try makeLocalFile(content: "0123456789ABCDEF")
		let temporaryFiles = try uuidNamedTemporaryFiles()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart, onRequest: { _ in
				try? Data("0123".utf8).write(to: localURL)
			}),
			URLProtocolMock.handler(body: "null"),
			URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 16, tagged: false))
		]

		await XCTAssertThrowsErrorAsync(try await value(of: Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
		})) { error in
			XCTAssertEqual(.unexpectedContent, error as? DropboxError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertEqual(temporaryFiles, try uuidNamedTemporaryFiles())
	}

	func testUploadSessionReportsBytesOfAppends() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = DropboxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart)]
			+ Array(repeating: URLProtocolMock.handler(body: "null"), count: 3)
			+ [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false))]

		_ = try await provider.uploadFile(from: makeLocalFile(content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

		let recordedFractions = fractions.withLock { $0 }
		XCTAssertEqual(3, recordedFractions.count)
		for (index, (fraction, (bytesBefore, chunkLength))) in zip(recordedFractions, [(0.0, 4.0), (4.0, 4.0), (8.0, 2.0)]).enumerated() {
			XCTAssertGreaterThan(fraction, (bytesBefore + chunkLength / 2) / 10, "chunk \(index)")
			XCTAssertLessThan(fraction, 1, "chunk \(index)")
		}
	}

	/// Bytes sent again after a corrected offset count on top of those sent so far, so the progress never completes before the last append.
	func testUploadSessionProgressCountsBytesSentAgain() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = DropboxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart),
			URLProtocolMock.handler(body: "null"),
			URLProtocolMock.handler(statusCode: 409, body: DropboxCloudProviderTests.incorrectOffset(2)),
			URLProtocolMock.handler(body: "null"),
			URLProtocolMock.handler(body: "null"),
			URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false))
		]

		_ = try await provider.uploadFile(from: makeLocalFile(content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

		// 16 bytes are sent in all: 0..<8, and 2..<10 again.
		let recordedFractions = fractions.withLock { $0 }
		XCTAssertEqual(4, recordedFractions.count)
		for (index, (fraction, (bytesBefore, chunkLength, totalLength))) in zip(recordedFractions, [(0.0, 4.0, 10.0), (4.0, 4.0, 10.0), (8.0, 4.0, 16.0), (12.0, 4.0, 16.0)]).enumerated() {
			XCTAssertGreaterThan(fraction, (bytesBefore + chunkLength / 2) / totalLength, "append \(index)")
			XCTAssertLessThan(fraction, 1, "append \(index)")
		}
	}

	func testCancellationBeforeFinishStopsUploadSession() async throws {
		let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 8)
		let localURL = try makeLocalFile(content: "0123456789")
		let upload = OSAllocatedUnfairLock<Task<CloudItemMetadata, Error>?>(initialState: nil)
		let started = XCTestExpectation(description: "upload started")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart),
			URLProtocolMock.handler(body: "null"),
			URLProtocolMock.handler(body: "null", onRequest: { _ in
				upload.withLock { $0 }?.cancel()
			}),
			URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false))
		]

		let task = Task {
			_ = await XCTWaiter().fulfillment(of: [started], timeout: testWaitTimeout)
			return try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
		}
		upload.withLock { $0 = task }
		started.fulfill()

		await XCTAssertThrowsErrorAsync(try await value(of: task)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	/// The finish is the commit point, so it runs with its retries also if the task is cancelled during its first attempt.
	func testCancelledUploadSessionStillFinishes() async throws {
		let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 16)
		let localURL = try makeLocalFile(content: "0123456789")
		let upload = OSAllocatedUnfairLock<Task<CloudItemMetadata, Error>?>(initialState: nil)
		let started = XCTestExpectation(description: "upload started")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart),
			URLProtocolMock.handler(body: "null"),
			URLProtocolMock.handler(statusCode: 503, onRequest: { _ in
				upload.withLock { $0 }?.cancel()
			}),
			URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false))
		]

		let task = Task {
			_ = await XCTWaiter().fulfillment(of: [started], timeout: testWaitTimeout)
			return try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
		}
		upload.withLock { $0 = task }
		started.fulfill()

		let metadata = try await value(of: task)
		XCTAssertEqual(10, metadata.size)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	// MARK: - Helpers

	private static func incorrectOffset(_ correctOffset: Int) -> String {
		return #"{"error_summary":"incorrect_offset/..","error":{".tag":"incorrect_offset","correct_offset":\#(correctOffset)}}"#
	}

	private static func argument(of request: URLRequest) -> [String: Any]? {
		return request.value(forHTTPHeaderField: "Dropbox-API-Arg").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
	}

	private static func appendOffset(of request: URLRequest) throws -> Int {
		return try XCTUnwrap((argument(of: request)?["cursor"] as? [String: Any])?["offset"] as? Int)
	}

	private func makeLocalFile(content: String) throws -> URL {
		let url = tmpDirURL.appendingPathComponent(UUID().uuidString)
		try Data(content.utf8).write(to: url)
		return url
	}
}

private struct TransferCase {
	let name: String
	let response: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let operation: @Sendable (DropboxCloudProvider, Progress) async throws -> Void
}

private struct ErrorCase {
	let summary: String
	let expectedError: Error
	let operation: @Sendable (DropboxCloudProvider) async throws -> Void
}
