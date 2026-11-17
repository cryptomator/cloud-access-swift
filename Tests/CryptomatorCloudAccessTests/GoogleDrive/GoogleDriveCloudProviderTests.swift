//
//  GoogleDriveCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 11.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class GoogleDriveCloudProviderTests {
		private static let rootWithFile = GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "F", name: "file.txt")])
		private static let rootWithFolder = GoogleDriveMockResponse.files([GoogleDriveMockResponse.folder(id: "D", name: "folder")])
		private static let emptyFolder = GoogleDriveMockResponse.files([])

		private let provider: GoogleDriveCloudProvider
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.provider = try GoogleDriveCloudProvider(client: .mocked())
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func throwsCancellationErrorInCancelledTask() async {
			await assertThrowsCancellationErrorInCancelledTask(provider)
		}

		// MARK: - Errors

		@Test
		func testConvertStandardError() {
			let wrappedCancellationError = NSError(domain: "Test", code: 0, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)])
			#expect(provider.convertStandardError(wrappedCancellationError) is CancellationError)
			let cases: [(GoogleDriveError, CloudProviderError)] = [
				(.apiError(statusCode: 401, reason: nil, message: nil), .unauthorized),
				(.apiError(statusCode: 403, reason: "insufficientPermissions", message: nil), .unauthorized),
				(.apiError(statusCode: 403, reason: "storageQuotaExceeded", message: nil), .quotaInsufficient),
				(.apiError(statusCode: 404, reason: "notFound", message: nil), .itemNotFound),
				(.apiError(statusCode: 507, reason: nil, message: nil), .quotaInsufficient)
			]
			for (error, expectedError) in cases {
				#expect(expectedError == (provider.convertStandardError(error) as? CloudProviderError), "\(error)")
			}
		}

		/// The client retried a rate limit until no attempt was left, which is no login failure.
		@Test
		func exceededRateLimitIsNotUnauthorized() {
			for reason in ["userRateLimitExceeded", "rateLimitExceeded"] {
				let error = GoogleDriveError.apiError(statusCode: 403, reason: reason, message: nil)

				#expect(error == (provider.convertStandardError(error) as? GoogleDriveError), "\(reason)")
			}
		}

		/// A 403 about an item, an action, a policy or a limit, or one without a reason, isn't fixed by signing in again.
		@Test
		func forbiddenWithoutMissingScopeIsNotUnauthorized() {
			for reason in ["insufficientFilePermissions", "appNotAuthorizedToFile", "teamDriveMembershipRequired", "domainPolicy", "dailyLimitExceeded", nil] {
				let error = GoogleDriveError.apiError(statusCode: 403, reason: reason, message: nil)

				#expect(error == (provider.convertStandardError(error) as? GoogleDriveError), "\(reason ?? "nil")")
			}
		}

		@Test
		func fullDriveThrowsQuotaInsufficient() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
				URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "storageQuotaExceeded"))
			]

			await #expect(throws: CloudProviderError.quotaInsufficient) { try await provider.createFolder(at: CloudPath("/folder")) }
		}

		/// A folder shared view-only refuses the upload, which signing in again wouldn't fix.
		@Test
		func uploadWithoutFilePermissionThrowsRawError() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
				URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "insufficientFilePermissions"))
			]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 403, reason: "insufficientFilePermissions", message: "Error")) { try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Listings

		@Test
		func listingSkipsShortcutWhoseTargetIsGoneOrPrivate() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([
					GoogleDriveMockResponse.file(id: "F", name: "file.txt"),
					GoogleDriveMockResponse.shortcut(id: "S1", name: "broken", targetID: "T1", targetMimeType: "text/plain"),
					GoogleDriveMockResponse.shortcut(id: "S2", name: "private", targetID: "T2", targetMimeType: "text/plain"),
					GoogleDriveMockResponse.shortcut(id: "S3", name: "forbidden", targetID: "T3", targetMimeType: "text/plain"),
					GoogleDriveMockResponse.shortcut(id: "S4", name: "link", targetID: "T4", targetMimeType: "application/vnd.google-apps.folder")
				])),
				URLProtocolMock.handler(statusCode: 404, body: GoogleDriveMockResponse.error(status: 404, reason: "notFound")),
				URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "insufficientFilePermissions")),
				URLProtocolMock.handler(statusCode: 403),
				URLProtocolMock.handler(body: #"{"mimeType":"application/vnd.google-apps.folder","modifiedTime":"\#(GoogleDriveMockResponse.modifiedTime)"}"#)
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			#expect([
				CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: GoogleDriveDate.date(fromRFC3339: GoogleDriveMockResponse.modifiedTime), size: 7),
				CloudItemMetadata(name: "link", cloudPath: CloudPath("/link"), itemType: .folder, lastModifiedDate: GoogleDriveDate.date(fromRFC3339: GoogleDriveMockResponse.modifiedTime), size: nil)
			] == itemList.items)
		}

		/// The listing fails if a shortcut's target request fails on the connection, through every retry, or as a login or quota failure, because the listing would otherwise look complete without the shortcut.
		@Test
		func listingFailsIfShortcutTargetRequestFails() async throws {
			let cases = [
				ShortcutTargetFailureCase(name: "connection", response: { _ in throw URLError(.networkConnectionLost) }, attemptCount: 5, expectedError: CloudProviderError.noInternetConnection),
				ShortcutTargetFailureCase(name: "rate limit", response: URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "rateLimitExceeded")), attemptCount: 5, expectedError: GoogleDriveError.apiError(statusCode: 403, reason: "rateLimitExceeded", message: "Error")),
				ShortcutTargetFailureCase(name: "missing scope", response: URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "insufficientPermissions")), attemptCount: 1, expectedError: CloudProviderError.unauthorized),
				ShortcutTargetFailureCase(name: "full drive", response: URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "storageQuotaExceeded")), attemptCount: 1, expectedError: CloudProviderError.quotaInsufficient)
			]
			for testCase in cases {
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.shortcut(id: "S1", name: "link", targetID: "T1", targetMimeType: "text/plain")]))
				] + Array(repeating: testCase.response, count: testCase.attemptCount)

				let error = try await #require(throws: (any Error).self, "\(testCase.name)") { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
				#expect(String(describing: testCase.expectedError) == String(describing: error), "\(testCase.name)")
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(testCase.name)")
			}
		}

		/// Drive accepts names that a cloud path can't hold. Such an item is neither listed nor cached, so that it shadows no path and doesn't replace the cached root.
		@Test
		func listingSkipsNamesThatAreNoSinglePathComponent() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([
					GoogleDriveMockResponse.file(id: "X1", name: "a/b"),
					GoogleDriveMockResponse.folder(id: "X2", name: ".."),
					GoogleDriveMockResponse.folder(id: "X3", name: "."),
					GoogleDriveMockResponse.folder(id: "X4", name: ""),
					GoogleDriveMockResponse.file(id: "F", name: "ok")
				])),
				URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder, onRequest: requests.record)
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/a/b")) }

			#expect([CloudPath("/ok")] == itemList.items.map(\.cloudPath))
			#expect(requests.requests.map { GoogleDriveCloudProviderTests.queryParameter("q", of: $0) } == ["'root' in parents and name contains 'a' and trashed = false"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func listingOfItemWithoutNameThrowsMissingItemName() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: GoogleDriveMockResponse.files([#"{"id":"F","mimeType":"text/plain"}"#]))]

			await #expect(throws: GoogleDriveError.missingItemName) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
		}

		/// A 400 on the first page is a bad request, which a restart of the listing wouldn't heal.
		@Test
		func badRequestIsPageTokenInvalidOnlyWithPageToken() async throws {
			let badRequest = URLProtocolMock.handler(statusCode: 400, body: GoogleDriveMockResponse.error(status: 400, reason: "invalid"))
			URLProtocolMock.requestHandler = [badRequest, badRequest]

			await #expect(throws: GoogleDriveError.apiError(statusCode: 400, reason: "invalid", message: "Error")) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			await #expect(throws: CloudProviderError.pageTokenInvalid) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "TOKEN") }
		}

		// MARK: - Lookups

		/// Drive can return a page without the item before the list ends.
		@Test
		func lookupFollowsPageTokens() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "B", name: "file.txt.bak")], nextPageToken: "P2"), onRequest: requests.record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "F", name: "file.txt")]), onRequest: requests.record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt"))
			]

			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			#expect(CloudPath("/file.txt") == metadata.cloudPath)
			#expect(requests.requests.map { GoogleDriveCloudProviderTests.queryParameter("pageToken", of: $0) } == [nil, "P2"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Shortcuts

		/// Requests for a shortcut's content and children go to its target, whereas a move or delete changes the shortcut itself.
		@Test
		func shortcutRequestsUseTargetOnlyForContent() async throws {
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
			#expect(sent.count == 16)
			#expect(sent[1].url?.path == "/drive/v3/files/T1")
			#expect(GoogleDriveCloudProviderTests.queryParameter("q", of: sent[2]) == "'T1' in parents and trashed = false")
			#expect(GoogleDriveCloudProviderTests.queryParameter("q", of: sent[3]) == "'T1' in parents and name contains 'file.txt' and trashed = false")
			#expect(try (["name": "file.txt", "parents": ["T1"]] as NSDictionary) == (JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[4])) as? NSDictionary))
			#expect(sent[7].url?.path == "/drive/v3/files/T2")
			#expect(sent[8].url?.path == "/download/drive/v3/files/T2")
			#expect([sent[10].httpMethod, sent[10].url?.path, GoogleDriveCloudProviderTests.queryParameter("addParents", of: sent[10]), GoogleDriveCloudProviderTests.queryParameter("removeParents", of: sent[10])] == ["PATCH", "/drive/v3/files/S2", "T1", "root"])
			#expect(try (["name": "new", "parents": ["T1"], "mimeType": GoogleDriveJSON.folderMimeType] as NSDictionary) == (JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[12])) as? NSDictionary))
			#expect([sent[14].url?.path, GoogleDriveCloudProviderTests.queryParameter("addParents", of: sent[14]), GoogleDriveCloudProviderTests.queryParameter("removeParents", of: sent[14])] == ["/drive/v3/files/F", "root", "T1"])
			#expect([sent[15].httpMethod, sent[15].url?.path] == ["DELETE", "/drive/v3/files/S1"])
		}

		/// Replacing a shortcut writes the content to its target, and the path stays the shortcut, so that deleting it afterwards deletes only the shortcut.
		@Test
		func replacingShortcutWritesToTargetAndKeepsShortcut() async throws {
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
			#expect(sent.count == 4)
			#expect([sent[1].httpMethod, sent[1].url?.path] == ["PATCH", "/upload/drive/v3/files/T"])
			#expect(try ([:] as NSDictionary) == (JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[1])) as? NSDictionary))
			#expect([sent[3].httpMethod, sent[3].url?.path] == ["DELETE", "/drive/v3/files/S"])
		}

		@Test
		func replacingShortcutToFolderThrowsItemAlreadyExists() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.shortcut(id: "S", name: "folder", targetID: "T", targetMimeType: GoogleDriveJSON.folderMimeType)]))
			]

			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/folder"), replaceExisting: true, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Moves

		/// A move stores the type of the moved item, so that the provider can download it afterwards.
		@Test
		func movedFileCanBeDownloaded() async throws {
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

			#expect(metadata.size == 7)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Transfers

		@Test
		func downloadAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider: GoogleDriveCloudProvider = provider
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
			let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
			let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", onRequest: { _ in
				#expect(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
			})]

			let metadata = try await cancellingValue(of: Task {
				try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: { task in
					taskStates.withLock { $0.append(task.state) }
					try? await Task.sleep(for: .milliseconds(100))
					onTaskCreationReturned.withLock { $0 = true }
				})
			})

			#expect(taskStates.withLock { $0 } == [.suspended])
			#expect(try Data("content".utf8) == Data(contentsOf: localURL))
			#expect(metadata.size == 7)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider: GoogleDriveCloudProvider = provider
			let localURL = try makeLocalFile(content: "file content")
			let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
			let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
				GoogleDriveMockResponse.session(),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12), onRequest: { _ in
					#expect(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
				})
			]

			let metadata = try await cancellingValue(of: Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { task in
					taskStates.withLock { $0.append(task.state) }
					try? await Task.sleep(for: .milliseconds(100))
					onTaskCreationReturned.withLock { $0 = true }
				})
			})

			#expect(taskStates.withLock { $0 } == [.suspended])
			#expect(CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: GoogleDriveDate.date(fromRFC3339: GoogleDriveMockResponse.modifiedTime), size: 12) == metadata)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadWithCancellationDuringOnTaskCreation() async throws {
			let provider: GoogleDriveCloudProvider = provider
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content")]

			let download = Task {
				try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: { _ in
					withUnsafeCurrentTask { $0?.cancel() }
				})
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }

			#expect(URLProtocolMock.requestHandler.count == 1, "The task of a cancelled download must not be resumed")
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func uploadWithCancellationDuringOnTaskCreation() async throws {
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
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }

			#expect(URLProtocolMock.requestHandler.count == 1, "The task of a cancelled upload must not be resumed")
		}

		@Test
		func failedDownloadThrowsItsErrorAndLeavesNoFile() async throws {
			let localURL = tmpDirURL.appendingPathComponent("download.txt")
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(statusCode: 404, body: GoogleDriveMockResponse.error(status: 404, reason: "notFound"))]

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil) }
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func downloadReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try GoogleDriveCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
		}

		@Test
		func uploadReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try GoogleDriveCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
				GoogleDriveMockResponse.session(),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt", size: 12))
			]

			_ = try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
		}

		/// Each attempt adds the progress of its task, so a retry takes half of the transfer's share instead of pushing it past complete.
		@Test
		func retriedDownloadSharesProgressWithFirstAttempt() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let fractionAtRetry = OSAllocatedUnfairLock<Double?>(initialState: nil)
			let provider = try GoogleDriveCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			URLProtocolMock.requestHandler = downloadPreparation() + [
				URLProtocolMock.handler(statusCode: 503, body: "BACKEND", headerFields: ["Content-Length": "7"]),
				URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"], onRequest: { _ in
					fractionAtRetry.withLock { $0 = progress.fractionCompleted }
				})
			]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

			try assertRetryHalvesProgress(fractions.withLock { $0 }, fractionAtRetry: fractionAtRetry.withLock { $0 })
		}

		@Test
		func putSentAgainSharesProgressWithFirstOne() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let fractionAtRetry = OSAllocatedUnfairLock<Double?>(initialState: nil)
			let provider = try GoogleDriveCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
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
		@Test
		func cancelledMutationsStillFinishTheirRequests() async throws {
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
				let canceller = TaskCanceller<Void>()
				URLProtocolMock.requestHandler = mutationCase.preparation + [
					URLProtocolMock.handler(statusCode: 503, onRequest: { _ in
						canceller.cancel()
					}),
					mutationCase.success
				]

				let task = canceller.start {
					try await mutationCase.operation(provider)
				}

				try await cancellingValue(of: task)
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(mutationCase.name)")
			}
		}

		/// A cancellation while a shortcut's target request is retried ends the listing.
		@Test
		func cancellationDuringShortcutResolutionEndsListing() async throws {
			let provider: GoogleDriveCloudProvider = provider
			let canceller = TaskCanceller<CloudItemList>()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([
					GoogleDriveMockResponse.shortcut(id: "S1", name: "link", targetID: "T1", targetMimeType: "text/plain"),
					GoogleDriveMockResponse.file(id: "F", name: "file.txt")
				])),
				URLProtocolMock.handler(statusCode: 503, onRequest: { _ in
					canceller.cancel()
				}),
				URLProtocolMock.handler(body: #"{"mimeType":"text/plain","modifiedTime":"\#(GoogleDriveMockResponse.modifiedTime)"}"#)
			]

			let task = canceller.start {
				return try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			}

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: task) }
		}

		// MARK: - Paths

		@Test
		func onlyItemNameChangedWorksWithFolders() {
			let oldCloudPath = CloudPath("/AAAAAA/BBBBBBB")
			let newCloudPathOnlyFolderNameChanged = CloudPath("/AAAAAA/CCCCCCC")
			#expect(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathOnlyFolderNameChanged))

			let newCloudPathWithParentFolderChanged = CloudPath("/DDDDDDD/BBBBBBB")
			#expect(!provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathWithParentFolderChanged))

			let newCloudPathParentFolderAndFolderNameChanged = CloudPath("/DDDDDDD/CCCCCCC")
			#expect(!provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathParentFolderAndFolderNameChanged))
		}

		@Test
		func onlyItemNameChangedWorksWithFiles() {
			let oldCloudPath = CloudPath("/AAAAAA/test.txt")
			let newCloudPathOnlyFileNameChanged = CloudPath("/AAAAAA/renamedTest.txt")
			#expect(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathOnlyFileNameChanged))

			let newCloudPathWithChangedPath = CloudPath("/DDDDDDD/BBBBBBB/test.txt")
			#expect(!provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathWithChangedPath))

			let newCloudPathWithPathAndFileNameChanged = CloudPath("/DDDDDDD/CCCCCCC/renamedAgainTest.txt")
			#expect(!provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathWithPathAndFileNameChanged))
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

		private func assertRetryHalvesProgress(_ fractions: [Double], fractionAtRetry: Double?, sourceLocation: SourceLocation = #_sourceLocation) throws {
			#expect(fractions.count == 2, "Unexpected number of transfer tasks", sourceLocation: sourceLocation)
			let fractionAfterFirstAttempt = try #require(fractions.first, sourceLocation: sourceLocation)
			#expect(fractionAfterFirstAttempt > 0.5, sourceLocation: sourceLocation)
			let fractionAtRetry = try #require(fractionAtRetry, sourceLocation: sourceLocation)
			let fractionAfterLastAttempt = try #require(fractions.last, sourceLocation: sourceLocation)
			#expect(abs(fractionAfterFirstAttempt / 2 - fractionAtRetry) <= 0.01, sourceLocation: sourceLocation)
			#expect(abs(fractionAfterFirstAttempt - fractionAfterLastAttempt) <= 0.01, sourceLocation: sourceLocation)
		}

		private static func queryParameter(_ name: String, of request: URLRequest) -> String? {
			return request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
		}

		private func assertTransferProgress(_ fractions: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
			#expect(fractions.count == 1, "Unexpected number of transfer tasks", sourceLocation: sourceLocation)
			#expect((fractions.first ?? 0) > 0.5, "The progress of the transfer task isn't part of the transfer's progress", sourceLocation: sourceLocation)
			#expect((fractions.first ?? 1) < 1, "The progress completed before the transfer returned", sourceLocation: sourceLocation)
		}
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
	/// How many attempts the client makes before it gives up.
	let attemptCount: Int
	let expectedError: Error
}
