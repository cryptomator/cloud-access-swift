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
			#expect(GoogleDriveCloudProvider.convertStandardError(wrappedCancellationError) is CancellationError)
			let cases: [(GoogleDriveError, CloudProviderError)] = [
				(.apiError(statusCode: 401, reason: nil, message: nil), .unauthorized),
				(.apiError(statusCode: 403, reason: "insufficientPermissions", message: nil), .unauthorized),
				(.apiError(statusCode: 403, reason: "storageQuotaExceeded", message: nil), .quotaInsufficient),
				(.apiError(statusCode: 404, reason: "notFound", message: nil), .itemNotFound),
				(.apiError(statusCode: 507, reason: nil, message: nil), .quotaInsufficient)
			]
			for (error, expectedError) in cases {
				#expect(expectedError == (GoogleDriveCloudProvider.convertStandardError(error) as? CloudProviderError), "\(error)")
			}
		}

		/// The client retried a rate limit until no attempt was left, which is no login failure.
		@Test
		func exceededRateLimitIsNotUnauthorized() {
			for reason in ["userRateLimitExceeded", "rateLimitExceeded"] {
				let error = GoogleDriveError.apiError(statusCode: 403, reason: reason, message: nil)

				#expect(error == (GoogleDriveCloudProvider.convertStandardError(error) as? GoogleDriveError), "\(reason)")
			}
		}

		/// A 403 about an item, an action, a policy or a limit, or one without a reason, isn't fixed by signing in again.
		@Test
		func forbiddenWithoutMissingScopeIsNotUnauthorized() {
			for reason in ["insufficientFilePermissions", "appNotAuthorizedToFile", "teamDriveMembershipRequired", "domainPolicy", "dailyLimitExceeded", nil] {
				let error = GoogleDriveError.apiError(statusCode: 403, reason: reason, message: nil)

				#expect(error == (GoogleDriveCloudProvider.convertStandardError(error) as? GoogleDriveError), "\(reason ?? "nil")")
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
					GoogleDriveMockResponse.shortcut(id: "S4", name: "link", targetID: "T4", targetMimeType: "application/vnd.google-apps.folder"),
					GoogleDriveMockResponse.shortcut(id: "S5", name: "link.txt", targetID: "T5", targetMimeType: "text/plain")
				])),
				URLProtocolMock.handler(statusCode: 404, body: GoogleDriveMockResponse.error(status: 404, reason: "notFound")),
				URLProtocolMock.handler(statusCode: 403, body: GoogleDriveMockResponse.error(status: 403, reason: "insufficientFilePermissions")),
				URLProtocolMock.handler(statusCode: 403),
				URLProtocolMock.handler(body: #"{"mimeType":"application/vnd.google-apps.folder","modifiedTime":"\#(GoogleDriveMockResponse.modifiedTime)"}"#),
				URLProtocolMock.handler(body: #"{"mimeType":"text/plain","modifiedTime":"\#(GoogleDriveMockResponse.modifiedTime)","size":"9"}"#)
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			#expect([
				CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: GoogleDriveDate.date(fromRFC3339: GoogleDriveMockResponse.modifiedTime), size: 7),
				CloudItemMetadata(name: "link", cloudPath: CloudPath("/link"), itemType: .folder, lastModifiedDate: GoogleDriveDate.date(fromRFC3339: GoogleDriveMockResponse.modifiedTime), size: nil),
				CloudItemMetadata(name: "link.txt", cloudPath: CloudPath("/link.txt"), itemType: .file, lastModifiedDate: GoogleDriveDate.date(fromRFC3339: GoogleDriveMockResponse.modifiedTime), size: 9)
			] == itemList.items)
			#expect(itemList.items.map(\.isAlias) == [false, true, true])
		}

		/// A shortcut without its target's type can't be resolved, so it lists as itself.
		@Test
		func listingMarksShortcutWithoutTargetTypeAsAlias() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.shortcut(id: "S", name: "link", targetID: "T", targetMimeType: nil)]))
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			#expect(itemList.items.map(\.itemType) == [.symlink])
			#expect(itemList.items.map(\.isAlias) == [true])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadThroughShortcutIsMarkedAsAlias() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([
					GoogleDriveMockResponse.file(id: "F", name: "file.txt"),
					GoogleDriveMockResponse.shortcut(id: "S", name: "link.txt", targetID: "T", targetMimeType: "text/plain")
				])),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "T", name: "target.txt")),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "T", name: "target.txt")),
				URLProtocolMock.handler(body: "content"),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt")),
				URLProtocolMock.handler(body: "content")
			]

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			let shortcutMetadata = try await provider.downloadFile(from: CloudPath("/link.txt"), to: tmpDirURL.appendingPathComponent("link.txt"), progress: nil, onTaskCreation: nil)
			let fileMetadata = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: nil, onTaskCreation: nil)

			#expect(shortcutMetadata.isAlias)
			#expect(!fileMetadata.isAlias)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Only the folder that holds the item counts, so that a vault reached through a shortcut stays usable.
		@Test
		func downloadBelowFolderShortcutIsMarkedAsAlias() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.shortcut(id: "S", name: "link", targetID: "T", targetMimeType: GoogleDriveJSON.folderMimeType)])),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "T", name: "target")),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "F", name: "file.txt"), GoogleDriveMockResponse.folder(id: "G", name: "sub")])),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "H", name: "file.txt")])),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "file.txt")),
				URLProtocolMock.handler(body: "content"),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "H", name: "file.txt")),
				URLProtocolMock.handler(body: "content")
			]

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/link"), withPageToken: nil)
			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/link/sub"), withPageToken: nil)
			let childMetadata = try await provider.downloadFile(from: CloudPath("/link/file.txt"), to: tmpDirURL.appendingPathComponent("child.txt"), progress: nil, onTaskCreation: nil)
			let grandchildMetadata = try await provider.downloadFile(from: CloudPath("/link/sub/file.txt"), to: tmpDirURL.appendingPathComponent("grandchild.txt"), progress: nil, onTaskCreation: nil)

			#expect(childMetadata.isAlias)
			#expect(!grandchildMetadata.isAlias)
			#expect(URLProtocolMock.requestHandler.isEmpty)
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
			#expect(requests.requests.map { URLProtocolMock.queryParameter("q", of: $0) } == ["'root' in parents and name contains 'a' and trashed = false"])
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
			#expect(requests.requests.map { URLProtocolMock.queryParameter("pageToken", of: $0) } == [nil, "P2"])
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

			let shortcutMetadata = try await provider.fetchItemMetadata(at: CloudPath("/folder"))
			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)
			_ = try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/folder/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
			_ = try await provider.downloadFile(from: CloudPath("/link.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)
			try await provider.moveFile(from: CloudPath("/link.txt"), to: CloudPath("/folder/link.txt"))
			try await provider.createFolder(at: CloudPath("/folder/new"))
			try await provider.moveFile(from: CloudPath("/folder/file.txt"), to: CloudPath("/moved.txt"))
			try await provider.deleteFolder(at: CloudPath("/folder"))

			#expect(!shortcutMetadata.isAlias)
			let sent = requests.requests
			#expect(sent.count == 16)
			#expect(sent[1].url?.path == "/drive/v3/files/T1")
			#expect(URLProtocolMock.queryParameter("q", of: sent[2]) == "'T1' in parents and trashed = false")
			#expect(URLProtocolMock.queryParameter("q", of: sent[3]) == "'T1' in parents and name contains 'file.txt' and trashed = false")
			#expect(try (["name": "file.txt", "parents": ["T1"]] as NSDictionary) == (JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[4])) as? NSDictionary))
			#expect(sent[7].url?.path == "/drive/v3/files/T2")
			#expect(sent[8].url?.path == "/download/drive/v3/files/T2")
			#expect([sent[10].httpMethod, sent[10].url?.path, URLProtocolMock.queryParameter("addParents", of: sent[10]), URLProtocolMock.queryParameter("removeParents", of: sent[10])] == ["PATCH", "/drive/v3/files/S2", "T1", "root"])
			#expect(try (["name": "new", "parents": ["T1"], "mimeType": GoogleDriveJSON.folderMimeType] as NSDictionary) == (JSONSerialization.jsonObject(with: URLProtocolMock.body(of: sent[12])) as? NSDictionary))
			#expect([sent[14].url?.path, URLProtocolMock.queryParameter("addParents", of: sent[14]), URLProtocolMock.queryParameter("removeParents", of: sent[14])] == ["/drive/v3/files/F", "root", "T1"])
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
				URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
				{ request in
					// Answers with the requested fields only, as Drive does.
					let fields = URLProtocolMock.queryParameter("fields", of: request) ?? ""
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

		/// The folder's cached row is replaced while the source is looked up, so the source is found in the new folder while the target's folder is the old one. The move fails before its request, rather than moving the file into the folder that left the path, and its retry renames the file in place.
		@Test
		func moveAfterFolderRowChangedFailsBeforeRequest() async throws {
			let tokenSource = HookedTokenSource()
			let provider = try GoogleDriveCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.folder(id: "P1", name: "p")])),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "P1", name: "p")),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.folder(id: "P2", name: "p")])),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "A1", name: "a")]), onRequest: requests.record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "A2", name: "a")]), onRequest: requests.record),
				URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder, onRequest: requests.record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "A2", name: "b"), onRequest: requests.record)
			]
			_ = try await provider.fetchItemMetadata(at: CloudPath("/p"))
			tokenSource.setHook(atCall: 3) {
				_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)
			}

			await #expect(throws: GoogleDriveError.inconsistentCache) { try await provider.moveFile(from: CloudPath("/p/a"), to: CloudPath("/p/b")) }
			#expect(requests.requests.count == 2)
			try await provider.moveFile(from: CloudPath("/p/a"), to: CloudPath("/p/b"))

			let sent = requests.requests
			try #require(sent.count == 4)
			#expect(sent.prefix(3).map { URLProtocolMock.queryParameter("q", of: $0) } == ["'P1' in parents and name contains 'a' and trashed = false", "'P2' in parents and name contains 'a' and trashed = false", "'P2' in parents and name contains 'b' and trashed = false"])
			#expect([sent[3].httpMethod, sent[3].url?.path, URLProtocolMock.queryParameter("addParents", of: sent[3]), URLProtocolMock.queryParameter("removeParents", of: sent[3])] == ["PATCH", "/drive/v3/files/A2", nil, nil])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The folder that a folder creation or a move writes into is replaced at its path before the request is sent, so the new item isn't cached below the replacement, and the next request on its path looks it up there.
		@Test(arguments: ["createFolder", "moveFile"])
		func mutationIntoReplacedFolderCachesNothing(operation: String) async throws {
			let tokenSource = HookedTokenSource()
			let provider = try GoogleDriveCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			let resolution = operation == "createFolder" ? [GoogleDriveCloudProviderTests.emptyFolder] : [GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "A", name: "a")]), GoogleDriveCloudProviderTests.emptyFolder]
			let response = operation == "createFolder" ? GoogleDriveMockResponse.folder(id: "N", name: "new") : GoogleDriveMockResponse.file(id: "A", name: "new")
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.folder(id: "P1", name: "p")])),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "P1", name: "p"))
			] + resolution.map { URLProtocolMock.handler(body: $0) } + [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.folder(id: "P2", name: "p")])),
				URLProtocolMock.handler(body: response),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.folder(id: "M", name: "new")]), onRequest: requests.record),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]
			_ = try await provider.fetchItemMetadata(at: CloudPath("/p"))
			tokenSource.setHook(atCall: 3 + resolution.count) {
				_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)
			}

			if operation == "createFolder" {
				try await provider.createFolder(at: CloudPath("/p/new"))
			} else {
				try await provider.moveFile(from: CloudPath("/p/a"), to: CloudPath("/p/new"))
			}
			try await provider.deleteFolder(at: CloudPath("/p/new"))

			let sent = requests.requests
			try #require(sent.count == 2)
			#expect(URLProtocolMock.queryParameter("q", of: sent[0]) == "'P2' in parents and name contains 'new' and trashed = false")
			#expect([sent[1].httpMethod, sent[1].url?.path] == ["DELETE", "/drive/v3/files/M"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A shortcut to the folder that holds the item leads to the same folder, so the move only renames the item.
		@Test
		func moveThroughShortcutToSameFolderIsRename() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.shortcut(id: "S", name: "alias", targetID: "R", targetMimeType: GoogleDriveJSON.folderMimeType), GoogleDriveMockResponse.folder(id: "R", name: "real")])),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "R", name: "real")),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "A", name: "a")])),
				URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "A", name: "b"), onRequest: requests.record)
			]
			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)

			try await provider.moveFile(from: CloudPath("/alias/a"), to: CloudPath("/real/b"))

			let request = try #require(requests.requests.first)
			#expect([request.httpMethod, request.url?.path] == ["PATCH", "/drive/v3/files/A"])
			#expect(URLProtocolMock.queryParameter("addParents", of: request) == nil)
			#expect(URLProtocolMock.queryParameter("removeParents", of: request) == nil)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Mutation Guards

		@Test
		func mutationGuardsSendNoRequestBeyondResolution() async throws {
			let cases = try MutationGuardCases.make(localURL: makeLocalFile(content: "content"), file: URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFile), folder: URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFolder), missing: URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder))

			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { try GoogleDriveCloudProvider(client: .mocked()) }
		}

		/// A shortcut without its target's type is a symbolic link, which is deleted as a file and never replaced.
		@Test
		func shortcutWithoutTargetTypeIsDeletedAsFile() async throws {
			let requests = RequestRecorder()
			let link = GoogleDriveMockResponse.files([GoogleDriveMockResponse.shortcut(id: "S", name: "link", targetID: "T", targetMimeType: nil)])
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: link),
				URLProtocolMock.handler(body: link),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.deleteFolder(at: CloudPath("/link")) }
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.uploadFile(from: makeLocalFile(content: "content"), to: CloudPath("/link"), replaceExisting: true, progress: nil, onTaskCreation: nil) }
			try await provider.deleteFile(at: CloudPath("/link"))

			#expect(requests.requests.map { [$0.httpMethod, $0.url?.path] } == [["DELETE", "/drive/v3/files/S"]])
		}

		/// An item without a MIME type is neither a file nor a folder, even with shortcut details.
		@Test
		func itemWithoutMIMETypeIsDeletedAsNeither() async throws {
			let items = [#"{"id":"X","name":"x"}"#, #"{"id":"Y","name":"y","shortcutDetails":{"targetId":"T","targetMimeType":"application/vnd.google-apps.folder"}}"#, #"{"id":"Z","name":"z","shortcutDetails":{"targetId":"U","targetMimeType":"text/plain"}}"#]
			URLProtocolMock.requestHandler = items.map { URLProtocolMock.handler(body: GoogleDriveMockResponse.files([$0])) }

			for name in ["x", "y"] {
				await #expect(throws: CloudProviderError.itemTypeMismatch, "\(name)") { try await provider.deleteFile(at: CloudPath("/\(name)")) }
				await #expect(throws: CloudProviderError.itemTypeMismatch, "\(name)") { try await provider.deleteFolder(at: CloudPath("/\(name)")) }
				await #expect(throws: CloudProviderError.itemTypeMismatch, "\(name)") { try await provider.fetchItemList(forFolderAt: CloudPath("/\(name)"), withPageToken: nil) }
			}
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.downloadFile(from: CloudPath("/z"), to: tmpDirURL.appendingPathComponent("z"), progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func shortcutToFolderIsDeletedAsFolder() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.shortcut(id: "S", name: "link", targetID: "T", targetMimeType: GoogleDriveJSON.folderMimeType)])),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.deleteFile(at: CloudPath("/link")) }
			try await provider.deleteFolder(at: CloudPath("/link"))

			#expect(requests.requests.map { [$0.httpMethod, $0.url?.path] } == [["DELETE", "/drive/v3/files/S"]])
		}

		// MARK: - Replacing Uploads

		/// The cached file was moved away or trashed, so the folder's lookup finds no file, and the upload creates a new one.
		@Test
		func replacingUploadOfMovedFileCreatesNewFile() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = downloadPreparation() + [
				URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder),
				GoogleDriveMockResponse.session(onRequest: requests.record),
				URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "N", name: "file.txt", size: 12))
			]
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			_ = try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil)

			#expect(requests.requests.map { [$0.httpMethod, $0.url?.path] } == [["POST", "/upload/drive/v3/files"]])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadWithoutReplacingOntoOtherFileThrowsItemAlreadyExists() async throws {
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: GoogleDriveMockResponse.files([GoogleDriveMockResponse.file(id: "G", name: "file.txt")]))]
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.uploadFile(from: makeLocalFile(content: "file content"), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
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
				GoogleDriveMutationCase(name: "move file", preparation: [URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFile), URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder)], success: URLProtocolMock.handler(body: GoogleDriveMockResponse.file(id: "F", name: "renamed.txt"))) { provider in
					try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))
				},
				GoogleDriveMutationCase(name: "move folder", preparation: [URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.rootWithFolder), URLProtocolMock.handler(body: GoogleDriveCloudProviderTests.emptyFolder)], success: URLProtocolMock.handler(body: GoogleDriveMockResponse.folder(id: "D", name: "renamed"))) { provider in
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

		private func assertTransferProgress(_ fractions: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
			#expect(fractions.count == 1, "Unexpected number of transfer tasks", sourceLocation: sourceLocation)
			#expect((fractions.first ?? 0) > 0.5, "The progress of the transfer task isn't part of the transfer's progress", sourceLocation: sourceLocation)
			#expect((fractions.first ?? 1) < 1, "The progress completed before the transfer returned", sourceLocation: sourceLocation)
		}
	}
}

/// Hands out a fixed token and runs a hook before handing out the token of one call, i.e., before that request is sent.
private final class HookedTokenSource: BearerTokenSource {
	private let state = OSAllocatedUnfairLock<(callCount: Int, hooks: [Int: @Sendable () async throws -> Void])>(initialState: (0, [:]))

	func setHook(atCall call: Int, _ hook: @escaping @Sendable () async throws -> Void) {
		state.withLock { $0.hooks[call] = hook }
	}

	func accessToken() async throws -> String {
		let hook = state.withLock { state in
			state.callCount += 1
			return state.hooks.removeValue(forKey: state.callCount)
		}
		try await hook?()
		return "TOKEN"
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		return "TOKEN"
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
