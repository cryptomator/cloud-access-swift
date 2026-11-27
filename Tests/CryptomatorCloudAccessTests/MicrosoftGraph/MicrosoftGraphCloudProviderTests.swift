//
//  MicrosoftGraphCloudProviderTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 26.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class MicrosoftGraphCloudProviderTests {
		private static let fileItem = #"{"id":"F","name":"file.txt","size":7,"file":{}}"#
		private static let folderItem = #"{"id":"D","name":"folder","folder":{}}"#
		private static let remoteFolderItem = #"{"id":"shortcut","name":"shared","remoteItem":{"id":"remote","folder":{},"parentReference":{"driveId":"remoteDrive"}}}"#
		private static let remoteFileItem = #"{"id":"fileShortcut","name":"shared.txt","remoteItem":{"id":"remoteFile","file":{},"parentReference":{"driveId":"remoteDrive"}}}"#
		private static let downloadURL = "https://content.example.com/dl/SECRET%2FPATH?tempauth=SECRET%3D"
		private static let fileItemWithDownloadURL = #"{"id":"F","name":"file.txt","size":7,"file":{},"fileSystemInfo":{"lastModifiedDateTime":"2026-11-16T10:00:00Z"},"@microsoft.graph.downloadUrl":"\#(MicrosoftGraphCloudProviderTests.downloadURL)"}"#
		private static let folderItemOnOtherDrive = #"{"id":"P","name":"Folder","folder":{},"parentReference":{"driveId":"D2"}}"#

		let provider: MicrosoftGraphCloudProvider
		let maxPageSize = 100
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.provider = try MicrosoftGraphCloudProvider(client: .mocked(), maxPageSize: maxPageSize)
			self.tmpDirURL = try makeTemporaryDirectory()
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func throwsCancellationErrorInCancelledTask() async {
			await assertThrowsCancellationErrorInCancelledTask(provider)
		}

		@Test
		func testConvertStandardError() {
			let cancellationError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
			#expect(MicrosoftGraphCloudProvider.convertStandardError(cancellationError) is CancellationError)
			#expect(MicrosoftGraphCloudProvider.convertStandardError(NSError(domain: "Test", code: 0, userInfo: [NSUnderlyingErrorKey: cancellationError])) is CancellationError)
			#expect((MicrosoftGraphCloudProvider.convertStandardError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) as? CloudProviderError) == .noInternetConnection)
		}

		@Test
		func uploadSessionURLIsNotLogged() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let localURL = try makeLocalFile(in: tmpDirURL)
			let folderBody = "{\"id\":\"FolderIdentifier\",\"name\":\"folder\",\"folder\":{}}"
			URLProtocolMock.requestHandler = [
				{ request in (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(folderBody.utf8)) },
				{ request in (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil) },
				{ request in (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"uploadUrl\":\"https://upload.example.com/up/SECRET-PATH-TOKEN?tempauth=SECRET-TEMPAUTH\"}".utf8)) },
				{ request in (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data("{\"id\":\"FileIdentifier\",\"name\":\"file.txt\",\"size\":7}".utf8)) }
			]

			_ = try await provider.uploadFile(from: localURL, to: CloudPath("/folder/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

			#expect(URLProtocolMock.requestHandler.isEmpty)
			#expect(!logCapture.joinedMessages.contains("SECRET"))
			#expect(logCapture.messages.contains { $0.hasPrefix("--> PUT https://upload.example.com") })
		}

		// MARK: - Listings

		@Test
		func listingRequestsTopAndSelectedFields() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"value":[]}"#, onRequest: requests.record)]

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			let request = try #require(requests.requests.first)
			#expect(request.httpMethod == "GET")
			#expect(request.url?.path == "/v1.0/me/drive/items/root/children")
			#expect(URLProtocolMock.queryParameter("$top", of: request) == "100")
			#expect(URLProtocolMock.queryParameter("$select", of: request) == "id,name,size,folder,fileSystemInfo,parentReference,remoteItem")
			#expect(request.url?.query(percentEncoded: true) == "%24top=100&%24select=id%2Cname%2Csize%2Cfolder%2CfileSystemInfo%2CparentReference%2CremoteItem")
		}

		@Test
		func pageTokenIsSentUnchanged() async throws {
			let pageToken = "https://graph.microsoft.com/v1.0/me/drive/items/root/children?$top=3&$skiptoken=a%3Db%2Bc"
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"value":[]}"#, onRequest: requests.record)]

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: pageToken)

			#expect(requests.requests.map(\.url?.absoluteString) == [pageToken])
		}

		/// A remote item's requests go to its own drive, whatever drive the provider addresses.
		@Test
		func itemDriveTakesPrecedenceOverProviderDrive() async throws {
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(), driveIdentifier: "D1")
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"value":[\#(MicrosoftGraphCloudProviderTests.remoteFolderItem)]}"#, onRequest: requests.record),
				URLProtocolMock.handler(body: #"{"value":[]}"#, onRequest: requests.record)
			]

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/shared"), withPageToken: nil)

			#expect(requests.requests.map(\.url?.path) == ["/v1.0/drives/D1/items/root/children", "/v1.0/drives/remoteDrive/items/remote/children"])
		}

		@Test
		func driveIdentifiersAreEscaped() async throws {
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(), driveIdentifier: "b!D")
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"value":[]}"#, onRequest: requests.record)]

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			#expect(requests.requests.map { $0.url?.path(percentEncoded: true) } == ["/v1.0/drives/b%21D/items/root/children"])
		}

		@Test
		func pageTokenOutsideGraphIsInvalidWithoutRequest() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"value":[]}"#)]

			for pageToken in ["https://evil.example/v1.0/me/drive/items/D/children?$skiptoken=X", "http://graph.microsoft.com/v1.0/me/drive/items/D/children", "https://graph.microsoft.com.evil.example/v1.0", "not a URL"] {
				await #expect(throws: CloudProviderError.pageTokenInvalid, "\(pageToken)") { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: pageToken) }
			}
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func badRequestForPageTokenIsPageTokenInvalid() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400)]

			await #expect(throws: CloudProviderError.pageTokenInvalid) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "https://graph.microsoft.com/v1.0/me/drive/items/D/children?$skiptoken=STALE") }
		}

		/// A page of 1000 items without `$select` is about 1.5 MB, which the metadata body limit must allow.
		@Test
		func fullPageOfChildrenIsListed() async throws {
			let padding = String(repeating: "x", count: 1360)
			let items = (0 ..< 1000).map { #"{"id":"ID\#($0)","name":"file\#($0).txt","size":7,"file":{"mimeType":"text/plain"},"description":"\#(padding)"}"# }
			let body = #"{"value":[\#(items.joined(separator: ","))]}"#
			#expect(body.utf8.count > 1_400_000)
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(), maxPageSize: 1000)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: body)]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			#expect(itemList.items.count == 1000)
		}

		/// A shared item added to My files lists as its target's type, and requests for its path reach the target.
		@Test
		func listingMarksRemoteItemAsAlias() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"value":[\#(MicrosoftGraphCloudProviderTests.remoteFolderItem),\#(MicrosoftGraphCloudProviderTests.remoteFileItem),\#(MicrosoftGraphCloudProviderTests.fileItem)]}"#)]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			#expect(itemList.items.map(\.cloudPath) == [CloudPath("/shared"), CloudPath("/shared.txt"), CloudPath("/file.txt")])
			#expect(itemList.items.map(\.itemType) == [.folder, .file, .file])
			#expect(itemList.items.map(\.isAlias) == [true, true, false])
		}

		@Test
		func downloadThroughRemoteItemIsMarkedAsAlias() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"value":[\#(MicrosoftGraphCloudProviderTests.remoteFileItem),\#(MicrosoftGraphCloudProviderTests.fileItem)]}"#),
				URLProtocolMock.handler(body: #"{"id":"remoteFile","name":"shared.txt","size":7,"file":{}}"#),
				URLProtocolMock.handler(body: "content"),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem),
				URLProtocolMock.handler(body: "content")
			]

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			let remoteItemMetadata = try await provider.downloadFile(from: CloudPath("/shared.txt"), to: tmpDirURL.appending(component: "shared.txt", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil)
			let fileMetadata = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil)

			#expect(remoteItemMetadata.isAlias)
			#expect(!fileMetadata.isAlias)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadBelowRemoteItemIsMarkedAsAlias() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"value":[\#(MicrosoftGraphCloudProviderTests.remoteFolderItem)]}"#),
				URLProtocolMock.handler(body: #"{"value":[\#(MicrosoftGraphCloudProviderTests.fileItem)]}"#),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem),
				URLProtocolMock.handler(body: "content")
			]

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/shared"), withPageToken: nil)
			let metadata = try await provider.downloadFile(from: CloudPath("/shared/file.txt"), to: tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil)

			#expect(metadata.isAlias)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A provider that lists a folder only through a page token, e.g. in a relaunched process, caches the folder's row before its children.
		@Test
		func downloadBelowRemoteItemListedThroughPageTokenIsMarkedAsAlias() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.remoteFolderItem),
				URLProtocolMock.handler(body: #"{"value":[\#(MicrosoftGraphCloudProviderTests.fileItem)]}"#),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem),
				URLProtocolMock.handler(body: "content")
			]

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/shared"), withPageToken: "https://graph.microsoft.com/v1.0/drives/remoteDrive/items/remote/children?$skiptoken=NEXT")
			let metadata = try await provider.downloadFile(from: CloudPath("/shared/file.txt"), to: tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil)

			#expect(metadata.isAlias)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func rootDownloadThrowsItemTypeMismatchWithoutRequest() async throws {
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.downloadFile(from: .root, to: tmpDirURL.appending(component: "root", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil) }
		}

		/// An item whose name is no single path component is neither listed nor cached, so that it shadows no path and doesn't replace the cached root.
		@Test
		func listingSkipsNamesThatAreNoSinglePathComponent() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"value":[{"id":"X1","name":".","folder":{}},{"id":"X2","name":"a/b","size":7,"file":{}},\#(MicrosoftGraphCloudProviderTests.fileItem)],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/drive/items/root/children?$skiptoken=NEXT"}"#),
				URLProtocolMock.handler(statusCode: 404, onRequest: requests.record)
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			await #expect(throws: (any Error).self) { try await provider.fetchItemMetadata(at: CloudPath("/a/b")) }

			#expect([CloudPath("/file.txt")] == itemList.items.map(\.cloudPath))
			#expect(itemList.nextPageToken == "https://graph.microsoft.com/v1.0/me/drive/items/root/children?$skiptoken=NEXT")
			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/root:/a:"])
			#expect(requests.requests.map { URLProtocolMock.queryParameter("$select", of: $0) } == [MicrosoftGraphAPI.DriveItem.selectedFields])
			#expect(logCapture.messages.count(where: { $0.hasSuffix("because its name is no single path component") }) == 2)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func listingOfItemWithoutNameThrowsMissingItemName() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"value":[{"id":"F","size":7,"file":{}}]}"#)]

			let error = try await #require(throws: (any Error).self) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			guard case MicrosoftGraphError.missingItemName = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		// MARK: - Metadata

		@Test
		func itemMetadataSelectsFields() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record)
			]

			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			#expect(metadata.size == 7)
			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/root:/file.txt:", "/v1.0/me/drive/items/F"])
			#expect(requests.requests.map { URLProtocolMock.queryParameter("$select", of: $0) } == [MicrosoftGraphAPI.DriveItem.selectedFields, MicrosoftGraphAPI.DriveItem.selectedFields])
		}

		@Test
		func pathLookupEscapesNameAsOneComponent() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 404, onRequest: requests.record)]

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/a=b #%.txt")) }

			#expect(requests.requests.map { $0.url?.path(percentEncoded: true) } == ["/v1.0/me/drive/items/root:/a%3Db%20%23%25.txt:"])
		}

		@Test
		func itemIdentifiersAreEscaped() async throws {
			let item = #"{"id":"A!1","name":"file.txt","file":{}}"#
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: item), URLProtocolMock.handler(body: item, onRequest: requests.record)]

			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			#expect(requests.requests.map { $0.url?.path(percentEncoded: true) } == ["/v1.0/me/drive/items/A%211"])
		}

		/// An inaccessible item answers 403, which signing in again wouldn't fix.
		@Test
		func forbiddenItemThrowsRawError() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 403)]

			let error = try await #require(throws: (any Error).self) { try await provider.fetchItemMetadata(at: CloudPath("/file.txt")) }
			guard case MicrosoftGraphError.unexpectedHTTPStatusCode(code: 403) = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Transfers

		@Test
		func downloadAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider = provider
			let localURL = tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory)
			let probe = OnTaskCreationProbe()
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", onRequest: { _ in probe.expectOnTaskCreationReturned() })]

			let metadata = try await cancellingValue(of: Task {
				try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: probe.onTaskCreation())
			})

			probe.expectAwaited()
			#expect(try Data("content".utf8) == Data(contentsOf: localURL))
			#expect(metadata.size == 7)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider = provider
			let localURL = try makeLocalFile(in: tmpDirURL)
			let probe = OnTaskCreationProbe()
			URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: { _ in probe.expectOnTaskCreationReturned() })]

			let metadata = try await cancellingValue(of: Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: probe.onTaskCreation())
			})

			probe.expectAwaited()
			#expect(metadata.size == 7)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadThroughSymbolicLinkSendsTarget() async throws {
			let linkURL = tmpDirURL.appending(component: "link.txt", directoryHint: .notDirectory)
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: makeLocalFile(in: tmpDirURL))
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record)]

			_ = try await provider.uploadFile(from: linkURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

			let chunk = try #require(requests.requests.first)
			#expect(chunk.value(forHTTPHeaderField: "Content-Range") == "bytes 0-6/7")
			#expect(chunk.httpBody == Data("content".utf8))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The chunks go to the upload URL exactly as the response spells it.
		@Test
		func uploadCreatesSessionByPath() async throws {
			let uploadURL = "https://upload.example.com/up/a%2Fb?tempauth=x%3Dy"
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 404),
				URLProtocolMock.handler(body: #"{"uploadUrl":"\#(uploadURL)"}"#, onRequest: requests.record),
				URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record)
			]

			_ = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL), to: CloudPath("/a=b.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

			let sentRequests = requests.requests
			try #require(sentRequests.count == 2)
			#expect(sentRequests[0].httpMethod == "POST")
			#expect(sentRequests[0].httpBody?.isEmpty ?? true)
			#expect(sentRequests[0].url?.path == "/v1.0/me/drive/items/root:/a=b.txt:/createUploadSession")
			#expect(sentRequests[0].url?.path(percentEncoded: true) == "/v1.0/me/drive/items/root:/a%3Db.txt:/createUploadSession")
			#expect(sentRequests[1].url?.absoluteString == uploadURL)
			#expect(sentRequests[1].httpMethod == "PUT")
			#expect(sentRequests[1].value(forHTTPHeaderField: "Content-Length") == "7")
			#expect(sentRequests[1].value(forHTTPHeaderField: "Content-Range") == "bytes 0-6/7")
		}

		@Test
		func downloadWithCancellationDuringOnTaskCreation() async {
			let provider = provider
			let localURL = tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory)
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content")]

			await expectCancelledBeforeResume {
				try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: cancellingOnTaskCreation())
			}

			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func uploadWithCancellationDuringOnTaskCreation() async throws {
			let provider = provider
			let localURL = try makeLocalFile(in: tmpDirURL)
			URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem)]

			await expectCancelledBeforeResume {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: cancellingOnTaskCreation())
			}
		}

		@Test
		func uploadOfSeveralChunksSendsEachChunkOnceAndHandsOverNoTask() async throws {
			let chunkLength = 5 * 1024 * 1024
			let content = Data((0 ..< chunkLength * 3 / 2).map { UInt8($0 % 251) })
			let localURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
			try content.write(to: localURL)
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			let chunks = OSAllocatedUnfairLock(initialState: [(method: String?, range: String?, body: Data)]())
			let fractionBeforeSecondChunk = OSAllocatedUnfairLock<Double?>(initialState: nil)
			let recordChunk: @Sendable (URLRequest) -> Void = { request in
				chunks.withLock { $0.append((request.httpMethod, request.value(forHTTPHeaderField: "Content-Range"), URLProtocolMock.body(of: request))) }
			}
			let taskCount = OSAllocatedUnfairLock(initialState: 0)
			URLProtocolMock.requestHandler = uploadPreparation() + [
				URLProtocolMock.handler(statusCode: 202, body: "{}", onRequest: recordChunk),
				URLProtocolMock.handler(statusCode: 201, body: #"{"id":"F","name":"file.txt","size":7864320,"file":{}}"#, onRequest: { request in
					fractionBeforeSecondChunk.withLock { $0 = progress.fractionCompleted }
					recordChunk(request)
				})
			]

			_ = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: { _ in
				taskCount.withLock { $0 += 1 }
			})

			let sentChunks = chunks.withLock { $0 }
			#expect(sentChunks.map(\.method) == ["PUT", "PUT"])
			#expect(sentChunks.map(\.range) == ["bytes 0-5242879/7864320", "bytes 5242880-7864319/7864320"])
			#expect([content.prefix(chunkLength), content.suffix(from: chunkLength)] == sentChunks.map(\.body))
			// The first chunk holds two thirds of the bytes.
			#expect(try abs(0.999 * 2 / 3 - #require(fractionBeforeSecondChunk.withLock { $0 })) <= 0.001)
			// The last chunk holds the remaining third, so the upload's share isn't exceeded.
			#expect(try abs(0.999 - #require(fractions.withLock { $0 }.last)) <= 0.001)
			#expect(taskCount.withLock { $0 } == 0)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The upload URL is pre-authenticated, so signing in again can't fix a refused chunk. A 404 concerns the upload session, not the item.
		@Test
		func refusedChunkThrowsErrorOfItsStatus() async throws {
			let cases: [(statusCode: Int, expectedError: Error)] = [
				(401, MicrosoftGraphError.unexpectedHTTPStatusCode(code: 401)),
				(403, MicrosoftGraphError.unexpectedHTTPStatusCode(code: 403)),
				(404, MicrosoftGraphError.unexpectedHTTPStatusCode(code: 404)),
				(507, CloudProviderError.quotaInsufficient)
			]
			let localURL = try makeLocalFile(in: tmpDirURL)
			for testCase in cases {
				URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: testCase.statusCode)]

				let error = try await #require(throws: (any Error).self, "\(testCase.statusCode)") { try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
				#expect(String(describing: testCase.expectedError) == String(describing: error), "\(testCase.statusCode)")
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(testCase.statusCode)")
			}
		}

		@Test
		func uploadSessionErrorsStopBeforeAnyChunk() async throws {
			let cases: [(sessionBody: String, expectsDecodingError: Bool)] = [("{}", false), (#"{"uploadUrl":""}"#, false), (#"{"uploadUrl":"http://upload.example.com/up/TOKEN"}"#, false), (#"{"uploadUrl":"https:/up/TOKEN"}"#, false), (#"{"uploadUrl":42}"#, true)]
			let localURL = try makeLocalFile(in: tmpDirURL)
			for testCase in cases {
				URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 404), URLProtocolMock.handler(body: testCase.sessionBody), URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem)]

				let error = try await #require(throws: (any Error).self, "\(testCase.sessionBody)") { try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
				switch error {
				case is DecodingError where testCase.expectsDecodingError, MicrosoftGraphError.unexpectedContent where !testCase.expectsDecodingError:
					break
				default:
					Issue.record("\(testCase.sessionBody): unexpected error \(error)")
				}
				#expect(URLProtocolMock.requestHandler.count == 1, "\(testCase.sessionBody)")
			}
		}

		@Test
		func downloadReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory), progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
		}

		@Test
		func uploadReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem)]

			_ = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
		}

		// MARK: - Download URL

		/// The date comes from the metadata request, because the path lookup's item has none.
		@Test
		func downloadFromDownloadURL() async throws {
			let requests = RequestRecorder()
			let localURL = tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItemWithDownloadURL, onRequest: requests.record),
				URLProtocolMock.handler(body: "content", onRequest: requests.record)
			]

			let metadata = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)

			let sentRequests = requests.requests
			try #require(sentRequests.count == 3)
			#expect(sentRequests[0].url?.path == "/v1.0/me/drive/items/root:/file.txt:")
			#expect(URLProtocolMock.queryParameter("$select", of: sentRequests[0]) == MicrosoftGraphAPI.DriveItem.selectedFields)
			#expect(["https://graph.microsoft.com/v1.0/me/drive/items/F", MicrosoftGraphCloudProviderTests.downloadURL] == sentRequests.dropFirst().map(\.url?.absoluteString))
			#expect(requests.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
			#expect(try Data("content".utf8) == Data(contentsOf: localURL))
			#expect(Date(timeIntervalSince1970: 1_794_823_200) == metadata.lastModifiedDate)
		}

		@Test
		func downloadWithoutUsableDownloadURLGoesThroughGraph() async throws {
			for metadataBody in [MicrosoftGraphCloudProviderTests.fileItem, MicrosoftGraphCloudProviderTests.fileItemWithDownloadURL.replacingOccurrences(of: "https://", with: "http://"), MicrosoftGraphCloudProviderTests.fileItemWithDownloadURL.replacingOccurrences(of: "https://", with: "https:/")] {
				let provider = try MicrosoftGraphCloudProvider(client: .mocked())
				let requests = RequestRecorder()
				let localURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem),
					URLProtocolMock.handler(body: metadataBody),
					URLProtocolMock.handler(body: "content", onRequest: requests.record)
				]

				_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)

				#expect([URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/F/content")] == requests.requests.map(\.url), "\(metadataBody)")
				#expect(requests.requests.first?.httpMethod == "GET", "\(metadataBody)")
				#expect(requests.requests.first?.httpBody?.isEmpty ?? true, "\(metadataBody)")
				#expect(requests.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN", "\(metadataBody)")
				#expect(try Data("content".utf8) == Data(contentsOf: localURL), "\(metadataBody)")
			}
		}

		@Test
		func refusedDownloadURLFallsBackToGraph() async throws {
			let requests = RequestRecorder()
			let localURL = tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory)
			URLProtocolMock.requestHandler = directDownloadPreparation() + [
				URLProtocolMock.handler(statusCode: 401),
				URLProtocolMock.handler(body: "content", onRequest: requests.record)
			]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)

			#expect([URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/F/content")] == requests.requests.map(\.url))
			#expect(requests.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
			#expect(try Data("content".utf8) == Data(contentsOf: localURL))
		}

		@Test
		func deletedFileThrowsItemNotFoundAfterFallback() async throws {
			let localURL = tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory)
			URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(statusCode: 404), URLProtocolMock.handler(statusCode: 404)]

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func otherSuccessOfDownloadURLFailsWithoutFallback() async throws {
			let localURL = tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory)
			URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(statusCode: 206, body: "con"), URLProtocolMock.handler(body: "content")]

			let error = try await #require(throws: (any Error).self) { try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil) }
			guard case MicrosoftGraphError.unexpectedHTTPStatusCode(code: 206) = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func downloadURLIsNotLogged() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: "content")]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil)

			#expect(logCapture.messages.contains { $0.hasPrefix("--> GET https://content.example.com") }, "\(logCapture.joinedMessages)")
			#expect(!logCapture.joinedMessages.contains("SECRET"), "\(logCapture.joinedMessages)")
		}

		@Test
		func downloadFromDownloadURLReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory), progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
		}

		@Test
		func fallbackHandsOverNoTask() async throws {
			let taskHosts = OSAllocatedUnfairLock(initialState: [String?]())
			URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: "content")]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory), progress: nil, onTaskCreation: { task in
				taskHosts.withLock { $0.append(task.originalRequest?.url?.host()) }
			})

			#expect(taskHosts.withLock { $0 } == ["content.example.com"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func fallbackReportsProgressOfItsTransfer() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractionBeforeFallback = OSAllocatedUnfairLock<Double?>(initialState: nil)
			let fractionsOfFallback = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks(willProcessCompletion: { task in
				if task is URLSessionDownloadTask, task.originalRequest?.url?.path.hasSuffix("/content") == true {
					fractionsOfFallback.withLock { $0.append(progress.fractionCompleted) }
				}
			})))
			URLProtocolMock.requestHandler = directDownloadPreparation() + [
				URLProtocolMock.handler(statusCode: 401, body: "refused", headerFields: ["Content-Length": "7"]),
				URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"], onRequest: { _ in
					fractionBeforeFallback.withLock { $0 = progress.fractionCompleted }
				})
			]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory), progress: progress, onTaskCreation: nil)

			let before = try #require(fractionBeforeFallback.withLock { $0 })
			let fallbackFractions = fractionsOfFallback.withLock { $0 }
			#expect(before < 0.9, "The refused transfer completed the download's progress")
			#expect(fallbackFractions.count == 1)
			#expect((fallbackFractions.first ?? 0) > before, "The progress of the fallback's task isn't part of the download's progress")
			#expect((fallbackFractions.first ?? 1) < 1, "The progress completed before the download returned")
		}

		@Test
		func cancellationBeforeFallbackStopsDownload() async throws {
			let provider = provider
			let localURL = tmpDirURL.appending(component: "file.txt", directoryHint: .notDirectory)
			let canceller = TaskCanceller<CloudItemMetadata>()
			URLProtocolMock.requestHandler = directDownloadPreparation() + [
				URLProtocolMock.handler(statusCode: 401, onRequest: { _ in
					canceller.cancel()
				}),
				URLProtocolMock.handler(body: "content")
			]

			let download = canceller.start {
				try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)
			}

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		// MARK: - Mutations

		@Test
		func createFolderPostsNameAndFolderFacet() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 404),
				URLProtocolMock.handler(statusCode: 201, body: #"{"id":"S","name":"subFolder","folder":{}}"#, onRequest: requests.record)
			]

			try await provider.createFolder(at: CloudPath("/subFolder"))

			let request = try #require(requests.requests.first)
			#expect(request.httpMethod == "POST")
			#expect(request.url?.path == "/v1.0/me/drive/items/root/children")
			#expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
			#expect(try (["@odata.type": "#microsoft.graph.driveItem", "name": "subFolder", "folder": NSDictionary()] as NSDictionary) == MicrosoftGraphCloudProviderTests.jsonBody(of: request))
		}

		@Test
		func createFolderThrowsErrorOfUnsuccessfulStatus() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 404),
				URLProtocolMock.handler(statusCode: 409, body: #"{"error":{"code":"nameAlreadyExists","message":"Name already exists"}}"#)
			]

			let error = try await #require(throws: (any Error).self) { try await provider.createFolder(at: CloudPath("/subFolder")) }
			guard case MicrosoftGraphError.unexpectedHTTPStatusCode(code: 409) = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		@Test
		func deleteSendsDeleteForItem() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]

			try await provider.deleteFile(at: CloudPath("/file.txt"))

			let request = try #require(requests.requests.first)
			#expect(request.httpMethod == "DELETE")
			#expect(request.url?.path == "/v1.0/me/drive/items/F")
			#expect(request.httpBody?.isEmpty ?? true)
		}

		/// The client can't tell whether an earlier attempt of a refused delete was applied, so the cached identifier is dropped, and the next read looks the path up.
		@Test
		func refusedDeleteThrowsAndDropsCachedItem() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem),
				URLProtocolMock.handler(statusCode: 403),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record)
			]

			let error = try await #require(throws: (any Error).self) { try await provider.deleteFile(at: CloudPath("/file.txt")) }
			guard case MicrosoftGraphError.unexpectedHTTPStatusCode(code: 403) = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/root:/file.txt:", "/v1.0/me/drive/items/F"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Graph may have applied a delete whose response was lost, so the next read looks the path up instead of reaching the item by its old identifier.
		@Test
		func deleteWithLostResponseLeavesPathUncached() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem),
				{ _ in throw URLError(.networkConnectionLost) },
				URLProtocolMock.handler(statusCode: 404, onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await provider.deleteFile(at: CloudPath("/file.txt")) }
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/file.txt")) }

			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/root:/file.txt:"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The new parent reference names the target folder's own drive.
		@Test
		func movePatchesNameAndParentsOwnDrive() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = movePreparation(folderItem: MicrosoftGraphCloudProviderTests.folderItemOnOtherDrive, onRequest: requests.record) + [
				URLProtocolMock.handler(body: #"{"id":"F","name":"renamed.txt","file":{},"parentReference":{"driveId":"D2"}}"#, onRequest: requests.record)
			]

			try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/Folder/renamed.txt"))

			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/root:/Folder:", "/v1.0/me/drive/items/root:/file.txt:", "/v1.0/drives/D2/items/P:/renamed.txt:", "/v1.0/me/drive/items/F"])
			let request = try #require(requests.requests.last)
			#expect(request.httpMethod == "PATCH")
			#expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
			#expect(try (["@odata.type": "#microsoft.graph.driveItem", "name": "renamed.txt", "parentReference": ["id": "P", "driveId": "D2"]] as NSDictionary) == MicrosoftGraphCloudProviderTests.jsonBody(of: request))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The provider's drive is never written into the new parent reference.
		@Test
		func moveIntoParentWithoutDriveOmitsDriveID() async throws {
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(), driveIdentifier: "D")
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = movePreparation(folderItem: #"{"id":"P","name":"Folder","folder":{}}"#, onRequest: requests.record) + [
				URLProtocolMock.handler(body: #"{"id":"F","name":"renamed.txt","file":{}}"#, onRequest: requests.record)
			]

			try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/Folder/renamed.txt"))

			#expect(requests.requests.map(\.url?.path) == ["/v1.0/drives/D/items/root:/Folder:", "/v1.0/drives/D/items/root:/file.txt:", "/v1.0/drives/D/items/P:/renamed.txt:", "/v1.0/drives/D/items/F"])
			let request = try #require(requests.requests.last)
			#expect(try (["@odata.type": "#microsoft.graph.driveItem", "name": "renamed.txt", "parentReference": ["id": "P"]] as NSDictionary) == MicrosoftGraphCloudProviderTests.jsonBody(of: request))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Graph accepted the move, so the source's cached item is gone even though the response can't be decoded.
		@Test
		func moveWithUndecodableResponseInvalidatesSource() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = movePreparation(folderItem: MicrosoftGraphCloudProviderTests.folderItemOnOtherDrive, onRequest: { _ in }) + [
				URLProtocolMock.handler(body: "{"),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record)
			]

			await #expect(throws: DecodingError.self) { try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/Folder/renamed.txt")) }
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/root:/file.txt:", "/v1.0/me/drive/items/F"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Mutation Guards

		@Test
		func mutationGuardsSendNoRequestBeyondResolution() async throws {
			let cases = try MutationGuardCases.make(localURL: makeLocalFile(in: tmpDirURL), file: URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem), folder: URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.folderItem), missing: URLProtocolMock.handler(statusCode: 404))

			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { try MicrosoftGraphCloudProvider(client: .mocked()) }
		}

		@Test
		func unresolvablePathsThrowWithoutRequest() async throws {
			let cases = try MutationGuardCases.makeInvalidPathCases(localURL: makeLocalFile(in: tmpDirURL), downloadURL: tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory), paths: MutationGuardCases.unresolvablePaths())
			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { try MicrosoftGraphCloudProvider(client: .mocked()) }
		}

		/// The target is looked up in its folder, so an item that replaced the cached one is found there without a request by the cached identifier.
		@Test
		func createFolderJudgesTargetByLookupNotCachedItem() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.folderItem),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.folderItem),
				URLProtocolMock.handler(body: #"{"id":"X","name":"folder","folder":{}}"#, onRequest: requests.record)
			]
			_ = try await provider.fetchItemMetadata(at: CloudPath("/folder"))

			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.createFolder(at: CloudPath("/folder")) }
			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/root:/folder:"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Cancellation

		/// A mutation's request is its commit point, so it runs with its retries also if the task is cancelled during the first attempt.
		@Test
		func cancelledMutationsStillFinishTheirRequests() async throws {
			let file = URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem)
			let folder = URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.folderItem)
			let notFound = URLProtocolMock.handler(statusCode: 404)
			let cases = [
				MicrosoftGraphMutationCase(name: "create folder", preparation: [notFound], success: URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.folderItem)) { try await $0.createFolder(at: CloudPath("/folder")) },
				MicrosoftGraphMutationCase(name: "delete file", preparation: [file], success: URLProtocolMock.handler(statusCode: 204)) { try await $0.deleteFile(at: CloudPath("/file.txt")) },
				MicrosoftGraphMutationCase(name: "delete folder", preparation: [folder], success: URLProtocolMock.handler(statusCode: 204)) { try await $0.deleteFolder(at: CloudPath("/folder")) },
				MicrosoftGraphMutationCase(name: "move file", preparation: [file, notFound], success: URLProtocolMock.handler(body: #"{"id":"F","name":"renamed.txt","file":{}}"#)) { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) },
				MicrosoftGraphMutationCase(name: "move folder", preparation: [folder, notFound], success: URLProtocolMock.handler(body: #"{"id":"D","name":"renamed","folder":{}}"#)) { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) }
			]
			for mutationCase in cases {
				let provider = try MicrosoftGraphCloudProvider(client: .mocked())
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

		/// A cancellation that arrives with the last lookup's response stops the mutation before its request.
		@Test
		func cancellationDuringLastLookupStopsMutationBeforeRequest() async throws {
			let cases = [
				MicrosoftGraphLookupCase(name: "createFolder", lookupPath: "/v1.0/me/drive/items/root:/subFolder:", response: URLProtocolMock.handler(statusCode: 404)) { try await $0.createFolder(at: CloudPath("/subFolder")) },
				MicrosoftGraphLookupCase(name: "deleteFile", lookupPath: "/v1.0/me/drive/items/root:/file.txt:", response: URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem)) { try await $0.deleteFile(at: CloudPath("/file.txt")) }
			]
			for testCase in cases {
				let provider = try MicrosoftGraphCloudProvider(client: .mocked())
				let canceller = TaskCanceller<Void>()
				let requests = RequestRecorder()
				URLProtocolMock.requestHandler = [
					{ request in
						requests.record(request)
						canceller.cancel()
						return try testCase.response(request)
					},
					URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.folderItem)
				]

				let task = canceller.start {
					try await testCase.operation(provider)
				}

				await #expect(throws: CancellationError.self, "\(testCase.name)") { try await cancellingValue(of: task) }
				#expect(requests.requests.map { [$0.httpMethod, $0.url?.path] } == [["GET", testCase.lookupPath]], "\(testCase.name)")
				#expect(URLProtocolMock.requestHandler.count == 1, "\(testCase.name)")
			}
		}

		// MARK: - Late Responses

		/// The listing's response names the file at the path that a rename freed and a new folder took, so it must not cache the file there, or deleting the folder would delete the renamed file.
		@Test(arguments: [nil, "https://graph.microsoft.com/v1.0/me/drive/items/root/children?$skiptoken=NEXT"] as [String?])
		func lateListingKeepsChildOutOfPathThatChanged(pageToken: String?) async throws {
			let tokenSource = HookedTokenSource()
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			let listing = #"{"value":[\#(MicrosoftGraphCloudProviderTests.fileItem)]}"#
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: listing),
				URLProtocolMock.handler(statusCode: 404),
				URLProtocolMock.handler(body: #"{"id":"F","name":"renamed.txt","file":{}}"#),
				URLProtocolMock.handler(statusCode: 404),
				URLProtocolMock.handler(statusCode: 201, body: #"{"id":"N","name":"file.txt","folder":{}}"#),
				URLProtocolMock.handler(body: listing),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]
			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)
			tokenSource.setHook(atCall: 2) {
				try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))
				try await provider.createFolder(at: CloudPath("/file.txt"))
			}

			let itemList = try await provider.fetchItemList(forFolderAt: .root, withPageToken: pageToken)
			try await provider.deleteFolder(at: CloudPath("/file.txt"))

			#expect(itemList.items.map(\.name) == ["file.txt"])
			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/N"])
		}

		/// The listed folder moved and a new folder took its path. No record names the child's path, so only the parent check keeps the moved folder's child out of the new folder.
		@Test
		func lateListingOfMovedFolderKeepsChildOut() async throws {
			let tokenSource = HookedTokenSource()
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"id":"D","name":"folder","folder":{}}"#),
				URLProtocolMock.handler(statusCode: 404),
				URLProtocolMock.handler(body: #"{"id":"D","name":"moved","folder":{}}"#),
				URLProtocolMock.handler(statusCode: 404),
				URLProtocolMock.handler(statusCode: 201, body: #"{"id":"N","name":"folder","folder":{}}"#),
				URLProtocolMock.handler(body: #"{"value":[{"id":"C","name":"x","file":{}}]}"#),
				URLProtocolMock.handler(statusCode: 404, onRequest: requests.record)
			]
			tokenSource.setHook(atCall: 2) {
				try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/moved"))
				try await provider.createFolder(at: CloudPath("/folder"))
			}

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.deleteFile(at: CloudPath("/folder/x")) }

			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/N:/x:"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The listing's mark precedes the lookup of its folder, so a change during that lookup refuses the listing's rows.
		@Test
		func listingWhoseFolderLookupSeesChangeKeepsChildOut() async throws {
			let tokenSource = HookedTokenSource()
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.folderItem),
				URLProtocolMock.handler(statusCode: 404),
				URLProtocolMock.handler(statusCode: 201, body: #"{"id":"N","name":"new","folder":{}}"#),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.folderItem),
				URLProtocolMock.handler(body: #"{"value":[{"id":"X","name":"new","folder":{}}]}"#),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]
			tokenSource.setHook(atCall: 1) {
				try await provider.createFolder(at: CloudPath("/folder/new"))
			}

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)
			try await provider.deleteFolder(at: CloudPath("/folder/new"))

			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/N"])
		}

		@Test(arguments: LateMutationKind.allCases)
		func lateMutationResponseLeavesMovedAwayTargetUncached(kind: LateMutationKind) async throws {
			let tokenSource = HookedTokenSource()
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(tokenSource: tokenSource))
			let testCase = try lateMutationCase(kind)
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = testCase.responses + [URLProtocolMock.handler(statusCode: 404, onRequest: requests.record)]
			tokenSource.setHook(atCall: testCase.preparation.count + 1) {
				try await testCase.rename(on: provider)
			}

			try await testCase.perform(on: provider)

			await testCase.expectTargetIsLookedUp(on: provider, requests: requests, lookupPath: "/v1.0/me/drive/items/root:/new:")
		}

		/// The item was deleted while its metadata was on the way, so the late response must not bring its row back.
		@Test(arguments: [false, true])
		func lateMetadataLeavesInvalidatedRowAlone(isDownload: Bool) async throws {
			let tokenSource = HookedTokenSource()
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(tokenSource: tokenSource))
			let localURL = tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory)
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"value":[\#(MicrosoftGraphCloudProviderTests.fileItem)]}"#),
				URLProtocolMock.handler(statusCode: 204),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem)
			] + (isDownload ? [URLProtocolMock.handler(body: "content")] : []) + [URLProtocolMock.handler(statusCode: 404, onRequest: requests.record)]
			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)
			tokenSource.setHook(atCall: 2) {
				try await provider.deleteFile(at: CloudPath("/file.txt"))
			}

			if isDownload {
				_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)
			} else {
				_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))
			}
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/file.txt")) }

			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/root:/file.txt:"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func metadataReadOfColdPathWarmsCache() async throws {
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem)]

			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Graph accepted the move, so the item's rows go although the response can't be decoded, and a listing that began before the move can't cache the item that the target held.
		@Test
		func moveWithUndecodableResponseEvictsItemAndRefusesOlderListing() async throws {
			let tokenSource = HookedTokenSource()
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"value":[{"id":"A","name":"a","file":{}},{"id":"A","name":"alias","file":{}}]}"#),
				URLProtocolMock.handler(statusCode: 404),
				URLProtocolMock.handler(body: "{"),
				URLProtocolMock.handler(body: #"{"value":[{"id":"D","name":"b","file":{}}]}"#),
				URLProtocolMock.handler(statusCode: 404, onRequest: requests.record),
				URLProtocolMock.handler(body: #"{"id":"A","name":"b","file":{}}"#),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]
			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)
			tokenSource.setHook(atCall: 2) {
				await #expect(throws: DecodingError.self) { try await provider.moveFile(from: CloudPath("/a"), to: CloudPath("/b")) }
			}

			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/alias")) }
			try await provider.deleteFile(at: CloudPath("/b"))

			#expect(requests.requests.map(\.url?.path) == ["/v1.0/me/drive/items/root:/alias:", "/v1.0/me/drive/items/A"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Helpers

		private func lateMutationCase(_ kind: LateMutationKind) throws -> LateMutationCase {
			let entry: (String) -> String = { name in
				kind == .createFolder ? #"{"id":"L","name":"\#(name)","folder":{}}"# : #"{"id":"L","name":"\#(name)","file":{}}"#
			}
			let notFound = URLProtocolMock.handler(statusCode: 404)
			let mutationResponses: [LateMutationCase.Response] = switch kind {
			case .upload: [URLProtocolMock.handler(body: #"{"uploadUrl":"https://upload.example.com/up/TOKEN"}"#), URLProtocolMock.handler(statusCode: 201, body: entry("new"))]
			case .createFolder: [URLProtocolMock.handler(statusCode: 201, body: entry("new"))]
			case .move: [URLProtocolMock.handler(body: entry("new"))]
			}
			return try LateMutationCase(kind: kind, localURL: makeLocalFile(in: tmpDirURL), preparation: kind == .move ? [URLProtocolMock.handler(body: entry("src")), notFound] : [notFound], renameResponses: [URLProtocolMock.handler(body: entry("new")), notFound, URLProtocolMock.handler(body: entry("moved"))], mutationResponses: mutationResponses)
		}

		/// The responses of the path lookup and the metadata request of `/file.txt`, before its download.
		private func downloadPreparation() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return [URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem), URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem)]
		}

		/// The responses of the path lookup and the metadata request of `/file.txt` before its download, the latter carrying a download URL.
		private func directDownloadPreparation() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return [URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem), URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItemWithDownloadURL)]
		}

		/// The responses of the lookup that finds no `/file.txt` and of the upload session request, before the upload's `PUT`.
		private func uploadPreparation() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return [URLProtocolMock.handler(statusCode: 404), URLProtocolMock.handler(body: #"{"uploadUrl":"https://upload.example.com/up/TOKEN"}"#)]
		}

		/// The responses of the lookups before a move of `/file.txt` to `/Folder/renamed.txt` with an empty cache: of the folder, of the source, and of the target, which isn't found.
		private func movePreparation(folderItem: String, onRequest: @escaping @Sendable (URLRequest) -> Void) -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return [
				URLProtocolMock.handler(body: folderItem, onRequest: onRequest),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: onRequest),
				URLProtocolMock.handler(statusCode: 404, onRequest: onRequest)
			]
		}

		private static func jsonBody(of request: URLRequest) throws -> NSDictionary? {
			return try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? NSDictionary
		}
	}
}

private struct MicrosoftGraphLookupCase {
	let name: String
	/// The path of the lookup that precedes the mutation's request.
	let lookupPath: String
	let response: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let operation: @Sendable (MicrosoftGraphCloudProvider) async throws -> Void
}

private struct MicrosoftGraphMutationCase {
	let name: String
	/// The responses to the requests before the mutation's request.
	let preparation: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)]
	/// The response to the retry of the mutation's request.
	let success: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let operation: @Sendable (MicrosoftGraphCloudProvider) async throws -> Void
}
