//
//  DropboxCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class DropboxCloudProviderTests {
		private static let uploadSessionStart = #"{"session_id":"SESSION"}"#

		private let provider: DropboxCloudProvider
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max)
			self.tmpDirURL = try makeTemporaryDirectory()
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func throwsCancellationErrorInCancelledTask() async {
			await assertThrowsCancellationErrorInCancelledTask(provider)
		}

		// MARK: - Metadata and Listings

		@Test
		func fetchItemMetadataOfFileAndFolder() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt")),
				URLProtocolMock.handler(body: DropboxMockResponse.folder(name: "folder"))
			]

			let file = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))
			let folder = try await provider.fetchItemMetadata(at: CloudPath("/folder"))

			#expect(CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: DropboxDate.date(from: DropboxMockResponse.serverModified), size: 7) == file)
			#expect(CloudItemMetadata(name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, lastModifiedDate: nil, size: nil) == folder)
		}

		@Test
		func fetchItemListConvertsEntriesAndReturnsCursorOnlyIfMore() async throws {
			let log = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxMockResponse.listing([DropboxMockResponse.file(name: "file.txt"), DropboxMockResponse.folder(name: "folder")], cursor: "NEXT", hasMore: true), onRequest: log.record),
				URLProtocolMock.handler(body: DropboxMockResponse.listing([], cursor: "LAST"), onRequest: log.record)
			]

			let firstPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			let lastPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "NEXT")

			#expect([CloudPath("/file.txt"), CloudPath("/folder")] == firstPage.items.map(\.cloudPath))
			#expect(firstPage.items.map(\.itemType) == [.file, .folder])
			#expect(firstPage.nextPageToken == "NEXT")
			#expect(lastPage.items.isEmpty)
			#expect(lastPage.nextPageToken == nil)
			let firstArgument = try #require(log.requests.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
			#expect((firstArgument["path"] as? String) == "")
			#expect((firstArgument["limit"] as? Int) == 2000)
		}

		@Test
		func listingSkipsNamesThatAreNoSinglePathComponent() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxMockResponse.listing([DropboxMockResponse.file(name: "a/b"), DropboxMockResponse.folder(name: ".."), DropboxMockResponse.file(name: "file.txt")]))]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			#expect([CloudPath("/file.txt")] == itemList.items.map(\.cloudPath))
		}

		@Test
		func untaggedListingEntryThrows() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxMockResponse.listing([DropboxMockResponse.file(name: "file.txt", tagged: false)]))]

			await #expect(throws: DropboxError.unexpectedContent) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
		}

		@Test
		func malformedCursorIsPageTokenInvalid() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400, body: "Error in call to API function \"files/list_folder/continue\": Invalid \"cursor\" parameter")]

			await #expect(throws: CloudProviderError.pageTokenInvalid) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "invalidPageToken") }
		}

		// MARK: - Errors

		@Test
		func routeErrorsAreConverted() async throws {
			let localURL = try makeLocalFile(in: tmpDirURL)
			let localTargetURL = tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory)
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

				let error = try await #require(throws: (any Error).self, "\(errorCase.summary)") { try await errorCase.operation(provider) }
				#expect(String(describing: errorCase.expectedError) == String(describing: error), "\(errorCase.summary)")
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(errorCase.summary)")
			}
		}

		@Test
		func rejectedTokenIsUnauthorized() async throws {
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 401, body: DropboxMockResponse.error("invalid_access_token/..")), count: 2)

			await #expect(throws: CloudProviderError.unauthorized) { try await provider.fetchItemMetadata(at: CloudPath("/file.txt")) }
		}

		@Test
		func suspendedAccountIsNotUnauthorized() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401, body: DropboxMockResponse.error("user_suspended/.."))]

			await #expect(throws: DropboxError.apiError(statusCode: 401, summary: "user_suspended/..")) { try await provider.fetchItemMetadata(at: CloudPath("/file.txt")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func missingParentFolderThrowsWithoutWriting() async throws {
			let localURL = try makeLocalFile(in: tmpDirURL)
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

				await #expect(throws: CloudProviderError.parentFolderDoesNotExist, "\(name)") { try await operation(provider) }
				#expect(log.requests.map { $0.url?.path } == ["/2/files/get_metadata"], "\(name)")
			}
		}

		/// Dropbox deletes and moves either type, so the wrong-type cases don't apply. Whether Dropbox answers a lookup below a file with `not_found` or `not_folder` is unknown, so the case below a file mid-path runs with both.
		@Test
		func mutationChecksFollowTheSharedContract() async throws {
			let localURL = try makeLocalFile(in: tmpDirURL)
			let fileParent = DropboxCloudProviderTests.response(to: "/2/files/get_metadata", path: "/file.txt", body: DropboxMockResponse.file(name: "file.txt"))
			let cases = MutationGuardCases.make(localURL: localURL) { kind in
				switch kind {
				case .deleteFileOfFolder, .deleteFolderOfFile, .moveFileOfFolder, .moveFolderOfFile:
					return nil
				case .createFolderInFile, .uploadFileIntoFile, .moveFileIntoFile, .moveFolderIntoFile:
					return [fileParent]
				case .createFolderBelowFileMidPath:
					return [DropboxCloudProviderTests.response(to: "/2/files/get_metadata", path: "/file.txt/x", statusCode: 409, body: DropboxMockResponse.error("path/not_found/.."))]
				case .missingSourceOntoExistingTarget:
					return [DropboxCloudProviderTests.response(to: "/2/files/move_v2", statusCode: 409, body: DropboxMockResponse.error("from_lookup/not_found/.."))]
				case .missingSourceIntoMissingParent:
					return [DropboxCloudProviderTests.response(to: "/2/files/get_metadata", path: "/missing", statusCode: 409, body: DropboxMockResponse.error("path/not_found/.."))]
				case .createFolderAtRoot, .uploadFileToRoot, .moveFileToRoot, .moveFolderToRoot, .deleteFileOfRoot, .deleteFolderOfRoot, .moveFileOfRoot, .moveFolderOfRoot:
					return []
				}
			}
			let notFolderCases = MutationGuardCases.make(localURL: localURL) { kind in
				kind == .createFolderBelowFileMidPath ? [DropboxCloudProviderTests.response(to: "/2/files/get_metadata", path: "/file.txt/x", statusCode: 409, body: DropboxMockResponse.error("path/not_folder/.."))] : nil
			}
			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases + notFolderCases) { DropboxCloudProvider(client: .mocked(), maxPageSize: .max) }
		}

		@Test
		func unresolvablePathsThrowWithoutRequest() async throws {
			let cases = try MutationGuardCases.makeInvalidPathCases(localURL: makeLocalFile(in: tmpDirURL), downloadURL: tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory), paths: MutationGuardCases.unresolvablePaths())
			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { DropboxCloudProvider(client: .mocked(), maxPageSize: .max) }
		}

		@Test
		func cancelledMutationsStillFinishTheirRequests() async throws {
			let operations: [(name: String, operation: @Sendable (DropboxCloudProvider) async throws -> Void)] = [
				("create folder", { try await $0.createFolder(at: CloudPath("/folder")) }),
				("delete file", { try await $0.deleteFile(at: CloudPath("/file.txt")) }),
				("delete folder", { try await $0.deleteFolder(at: CloudPath("/folder")) }),
				("move file", { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) }),
				("move folder", { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) })
			]
			for (name, operation) in operations {
				let provider: DropboxCloudProvider = provider
				let canceller = TaskCanceller<Void>()
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(statusCode: 503, onRequest: { _ in
						canceller.cancel()
					}),
					URLProtocolMock.handler(body: "{}")
				]

				let task = canceller.start {
					try await operation(provider)
				}

				try await cancellingValue(of: task)
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(name)")
			}
		}

		// MARK: - Transfers

		@Test
		func downloadAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider: DropboxCloudProvider = provider
			let localURL = tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory)
			let probe = OnTaskCreationProbe()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "content", headerFields: ["Dropbox-API-Result": DropboxMockResponse.file(name: "file.txt", tagged: false)], onRequest: { _ in probe.expectOnTaskCreationReturned() })]

			let metadata = try await cancellingValue(of: Task {
				try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: probe.onTaskCreation())
			})

			probe.expectAwaited()
			#expect(try Data("content".utf8) == Data(contentsOf: localURL))
			#expect(CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: DropboxDate.date(from: DropboxMockResponse.serverModified), size: 7) == metadata)
		}

		@Test
		func uploadAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider: DropboxCloudProvider = provider
			let localURL = try makeLocalFile(in: tmpDirURL)
			let probe = OnTaskCreationProbe()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", tagged: false), onRequest: { _ in probe.expectOnTaskCreationReturned() })]

			let metadata = try await cancellingValue(of: Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: probe.onTaskCreation())
			})

			probe.expectAwaited()
			#expect(CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: DropboxDate.date(from: DropboxMockResponse.serverModified), size: 7) == metadata)
		}

		@Test
		func cancellationDuringOnTaskCreationSendsNoTransfer() async throws {
			let provider: DropboxCloudProvider = provider
			let localURL = try makeLocalFile(in: tmpDirURL)
			let downloadURL = tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "content")]

			await expectCancelledBeforeResume {
				try await provider.downloadFile(from: CloudPath("/file.txt"), to: downloadURL, progress: nil, onTaskCreation: cancellingOnTaskCreation())
			}
			await expectCancelledBeforeResume {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: cancellingOnTaskCreation())
			}
			#expect(!FileManager.default.fileExists(atPath: downloadURL.path))
		}

		@Test
		func transfersReportBytesOfTask() async throws {
			let localURL = try makeLocalFile(in: tmpDirURL)
			let downloadURL = tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory)
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

				assertTransferProgress(fractions.withLock { $0 }, "\(name)")
			}
		}

		/// Each attempt adds the progress of its task, so a retry takes half of the transfer's share instead of pushing it past complete.
		@Test
		func retriedDownloadSharesProgressWithFirstAttempt() async throws {
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

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory), progress: progress, onTaskCreation: nil)

			try assertRetryHalvesProgress(fractions.withLock { $0 }, fractionAtRetry: fractionAtRetry.withLock { $0 })
		}

		@Test
		func uploadModeFollowsReplaceExisting() async throws {
			let localURL = try makeLocalFile(in: tmpDirURL)
			let largeLocalURL = try makeLocalFile(in: tmpDirURL, content: "0123456789")
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
				#expect(requests.map { $0.url?.path } == ["/2/files/upload", "/2/files/upload_session/finish"])
				#expect(try expectedMode == (#require(requests.first.flatMap(DropboxCloudProviderTests.argument))["mode"] as? String))
				#expect(try expectedMode == ((#require(requests.last.flatMap(DropboxCloudProviderTests.argument))["commit"] as? [String: Any])?["mode"] as? String))
			}
		}

		@Test
		func uploadThroughSymbolicLinkSendsTarget() async throws {
			let linkURL = tmpDirURL.appending(component: "link.txt", directoryHint: .notDirectory)
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: makeLocalFile(in: tmpDirURL))
			let recorder = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", tagged: false), onRequest: recorder.record)]

			_ = try await provider.uploadFile(from: linkURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

			#expect(recorder.requests.map(\.httpBody) == [Data("content".utf8)])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Upload Sessions

		@Test
		func largeUploadAppendsChunksFromFilesAndFinishes() async throws {
			let appendTasks = OSAllocatedUnfairLock(initialState: [(isUploadTask: Bool, hasBody: Bool)]())
			let hooks = SplitURLSession.Hooks(willProcessCompletion: { task in
				if task.originalRequest?.url?.path == "/2/files/upload_session/append_v2" {
					appendTasks.withLock { $0.append((task is URLSessionUploadTask, task.originalRequest?.httpBody != nil)) }
				}
			})
			let provider = DropboxCloudProvider(client: .mocked(hooks: hooks), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
			let localURL = try makeLocalFile(in: tmpDirURL, content: "0123456789")
			let temporaryFiles = try uuidNamedTemporaryFiles()
			let log = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart, onRequest: log.record)]
				+ Array(repeating: URLProtocolMock.handler(body: "null", onRequest: log.record), count: 3)
				+ [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false), onRequest: log.record)]

			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

			#expect(metadata.size == 10)
			#expect(try temporaryFiles == uuidNamedTemporaryFiles())
			let requests = log.requests
			#expect(requests.map { $0.url?.lastPathComponent } == ["start", "append_v2", "append_v2", "append_v2", "finish"])
			#expect(try requests[1 ... 3].map(DropboxCloudProviderTests.appendOffset) == [0, 4, 8])
			#expect(requests[1 ... 3].map { String(bytes: $0.httpBody ?? Data(), encoding: .utf8) } == ["0123", "4567", "89"])
			let finishArgument = try #require(DropboxCloudProviderTests.argument(of: requests[4]))
			#expect(((finishArgument["cursor"] as? [String: Any])?["offset"] as? Int) == 10)
			#expect(((finishArgument["commit"] as? [String: Any])?["path"] as? String) == "/file.txt")
			let tasks = appendTasks.withLock { $0 }
			#expect(tasks.count == 3)
			#expect(tasks.allSatisfy { $0.isUploadTask && !$0.hasBody })
		}

		@Test
		func incorrectOffsetContinuesFromCorrectOffset() async throws {
			let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
			let log = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart),
				URLProtocolMock.handler(statusCode: 409, body: DropboxCloudProviderTests.incorrectOffset(8), onRequest: log.record),
				URLProtocolMock.handler(body: "null", onRequest: log.record),
				URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false))
			]

			_ = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

			#expect(try log.requests.map(DropboxCloudProviderTests.appendOffset) == [0, 8])
			#expect(log.requests.map { String(bytes: $0.httpBody ?? Data(), encoding: .utf8) } == ["0123", "89"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Each append's response is lost, so its repeat is answered with the offset after the chunk.
		@Test
		func lostAppendResponsesComplete() async throws {
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

			let metadata = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, content: "0123456789ABCDEF"), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

			#expect(metadata.size == 16)
			#expect(sleeps.durations.count == 4)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadGivesUpWhenDropboxStopsConfirmingProgress() async throws {
			let accepted = URLProtocolMock.handler(body: "null")
			let rewound = URLProtocolMock.handler(statusCode: 409, body: DropboxCloudProviderTests.incorrectOffset(0))
			let cases: [(name: String, appends: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)])] = [
				("stuck", Array(repeating: rewound, count: 4)),
				("rewinding every third request", Array(repeating: [accepted, accepted, rewound], count: 4).flatMap(\.self))
			]
			for (name, appends) in cases {
				let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
				let localURL = try makeLocalFile(in: tmpDirURL, content: "0123456789ABCDEF")
				let temporaryFiles = try uuidNamedTemporaryFiles()
				URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart)] + appends + [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 16, tagged: false))]

				await #expect(throws: DropboxError.unexpectedContent, "\(name)") { try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
				#expect(URLProtocolMock.requestHandler.count == 1, "\(name)")
				#expect(try temporaryFiles == uuidNamedTemporaryFiles(), "\(name)")
			}
		}

		@Test
		func correctOffsetOutsideFileThrows() async throws {
			for correctOffset in [-1, 17] {
				let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart),
					URLProtocolMock.handler(statusCode: 409, body: DropboxCloudProviderTests.incorrectOffset(correctOffset)),
					URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 16, tagged: false))
				]

				await #expect(throws: DropboxError.unexpectedContent, "\(correctOffset)") { try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, content: "0123456789ABCDEF"), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
				#expect(URLProtocolMock.requestHandler.count == 1, "\(correctOffset)")
			}
		}

		@Test
		func fileThatGetsShorterDuringUploadThrows() async throws {
			let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
			let localURL = try makeLocalFile(in: tmpDirURL, content: "0123456789ABCDEF")
			let temporaryFiles = try uuidNamedTemporaryFiles()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart, onRequest: { _ in
					try? Data("0123".utf8).write(to: localURL)
				}),
				URLProtocolMock.handler(body: "null"),
				URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 16, tagged: false))
			]

			await #expect(throws: DropboxError.unexpectedContent) {
				try await cancellingValue(of: Task {
					try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
				})
			}
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(try temporaryFiles == uuidNamedTemporaryFiles())
		}

		@Test
		func uploadSessionReportsBytesOfAppends() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = DropboxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 4)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart)]
				+ Array(repeating: URLProtocolMock.handler(body: "null"), count: 3)
				+ [URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false))]

			_ = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 }, parts: [(4, 10), (4, 10), (2, 10)])
		}

		/// Bytes sent again after a corrected offset count on top of those sent so far, so the progress never completes before the last append.
		@Test
		func uploadSessionProgressCountsBytesSentAgain() async throws {
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

			_ = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

			// 16 bytes are sent in all: 0..<8, and 2..<10 again.
			assertTransferProgress(fractions.withLock { $0 }, parts: [(4, 10), (4, 10), (4, 16), (4, 16)])
		}

		@Test
		func cancellationBeforeFinishStopsUploadSession() async throws {
			let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 8)
			let localURL = try makeLocalFile(in: tmpDirURL, content: "0123456789")
			let canceller = TaskCanceller<CloudItemMetadata>()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart),
				URLProtocolMock.handler(body: "null"),
				URLProtocolMock.handler(body: "null", onRequest: { _ in
					canceller.cancel()
				}),
				URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false))
			]

			let task = canceller.start {
				return try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
			}

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: task) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		/// The finish is the commit point, so it runs with its retries also if the task is cancelled during its first attempt.
		@Test
		func cancelledUploadSessionStillFinishes() async throws {
			let provider = DropboxCloudProvider(client: .mocked(), maxPageSize: .max, uploadSessionThreshold: 10, uploadSessionChunkLength: 16)
			let localURL = try makeLocalFile(in: tmpDirURL, content: "0123456789")
			let canceller = TaskCanceller<CloudItemMetadata>()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxCloudProviderTests.uploadSessionStart),
				URLProtocolMock.handler(body: "null"),
				URLProtocolMock.handler(statusCode: 503, onRequest: { _ in
					canceller.cancel()
				}),
				URLProtocolMock.handler(body: DropboxMockResponse.file(name: "file.txt", size: 10, tagged: false))
			]

			let task = canceller.start {
				return try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
			}

			let metadata = try await cancellingValue(of: task)
			#expect(metadata.size == 10)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Helpers

		private static func incorrectOffset(_ correctOffset: Int) -> String {
			return #"{"error_summary":"incorrect_offset/..","error":{".tag":"incorrect_offset","correct_offset":\#(correctOffset)}}"#
		}

		/// Answers a request to the route, with the path as its JSON argument's `path` if one is given, and fails any other request, so that a lookup of another path fails the test.
		private static func response(to route: String, path: String? = nil, statusCode: Int = 200, body: String) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
			let response = URLProtocolMock.handler(statusCode: statusCode, body: body)
			return { request in
				let argument = try? JSONSerialization.jsonObject(with: URLProtocolMock.body(of: request)) as? [String: Any]
				guard request.url?.path == route, path == nil || argument?["path"] as? String == path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return try response(request)
			}
		}

		private static func argument(of request: URLRequest) -> [String: Any]? {
			return request.value(forHTTPHeaderField: "Dropbox-API-Arg").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
		}

		private static func appendOffset(of request: URLRequest) throws -> Int {
			return try #require((argument(of: request)?["cursor"] as? [String: Any])?["offset"] as? Int)
		}
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
