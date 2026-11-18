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
		private static let remoteFileItem = #"{"id":"fileShortcut","name":"shared.txt","remoteItem":{"id":"remoteFile","file":{},"parentReference":{"driveId":"remoteDrive"}}}"#
		private static let downloadURL = "https://content.example.com/dl/SECRET-PATH?tempauth=SECRET"
		private static let fileItemWithDownloadURL = #"{"id":"F","name":"file.txt","size":7,"file":{},"fileSystemInfo":{"lastModifiedDateTime":"2026-11-16T10:00:00Z"},"@microsoft.graph.downloadUrl":"\#(MicrosoftGraphCloudProviderTests.downloadURL)"}"#

		let provider: MicrosoftGraphCloudProvider
		let maxPageSize = 100
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.provider = try MicrosoftGraphCloudProvider(client: .mocked(), maxPageSize: maxPageSize)
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

		@Test
		func testConvertStandardError() {
			let cancellationError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
			#expect(provider.convertStandardError(cancellationError) is CancellationError)
			#expect(provider.convertStandardError(NSError(domain: "Test", code: 0, userInfo: [NSUnderlyingErrorKey: cancellationError])) is CancellationError)
			#expect((provider.convertStandardError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) as? CloudProviderError) == .noInternetConnection)
		}

		@Test
		func uploadSessionURLIsNotLogged() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let localURL = try makeLocalFile(content: "content")
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
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"value":[{"id":"shortcut","name":"shared","remoteItem":{"id":"remote","folder":{},"parentReference":{"driveId":"remoteDrive"}}},\#(MicrosoftGraphCloudProviderTests.remoteFileItem),\#(MicrosoftGraphCloudProviderTests.fileItem)]}"#)]

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
			let remoteItemMetadata = try await provider.downloadFile(from: CloudPath("/shared.txt"), to: tmpDirURL.appendingPathComponent("shared.txt"), progress: nil, onTaskCreation: nil)
			let fileMetadata = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: nil, onTaskCreation: nil)

			#expect(remoteItemMetadata.isAlias)
			#expect(!fileMetadata.isAlias)
			#expect(URLProtocolMock.requestHandler.isEmpty)
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
			#expect([URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/root:/a:?$select=id,name,size,folder,fileSystemInfo,parentReference,remoteItem")] == requests.requests.map(\.url))
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
			#expect([
				URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/root:/file.txt:?$select=id,name,size,folder,fileSystemInfo,parentReference,remoteItem"),
				URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/F?$select=id,name,size,folder,fileSystemInfo,parentReference,remoteItem")
			] == requests.requests.map(\.url))
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
			let provider = provider
			let localURL = try makeLocalFile(content: "content")
			let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
			let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
			URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: { _ in
				#expect(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
			})]

			let metadata = try await cancellingValue(of: Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { task in
					taskStates.withLock { $0.append(task.state) }
					try? await Task.sleep(for: .milliseconds(100))
					onTaskCreationReturned.withLock { $0 = true }
				})
			})

			#expect(taskStates.withLock { $0 } == [.suspended])
			#expect(metadata.size == 7)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadThroughSymbolicLinkSendsTarget() async throws {
			let linkURL = tmpDirURL.appendingPathComponent("link.txt")
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: makeLocalFile(content: "content"))
			let chunk = OSAllocatedUnfairLock<(range: String?, body: Data)?>(initialState: nil)
			URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: { request in
				chunk.withLock { $0 = (request.value(forHTTPHeaderField: "Content-Range"), URLProtocolMock.body(of: request)) }
			})]

			_ = try await provider.uploadFile(from: linkURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

			let sentChunk = try #require(chunk.withLock { $0 })
			#expect(sentChunk.range == "bytes 0-6/7")
			#expect(sentChunk.body == Data("content".utf8))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadWithCancellationDuringOnTaskCreation() async throws {
			let provider = provider
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
			let provider = provider
			let localURL = try makeLocalFile(content: "content")
			URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem)]

			let upload = Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
					withUnsafeCurrentTask { $0?.cancel() }
				})
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }

			#expect(URLProtocolMock.requestHandler.count == 1, "The task of a cancelled upload must not be resumed")
		}

		@Test
		func uploadOfSeveralChunksSendsEachChunkOnceAndHandsOverNoTask() async throws {
			let chunkLength = 5 * 1024 * 1024
			let content = Data((0 ..< chunkLength * 3 / 2).map { UInt8($0 % 251) })
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
			try content.write(to: localURL)
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			let chunks = OSAllocatedUnfairLock(initialState: [(range: String?, body: Data)]())
			let fractionBeforeSecondChunk = OSAllocatedUnfairLock<Double?>(initialState: nil)
			let recordChunk: @Sendable (URLRequest) -> Void = { request in
				chunks.withLock { $0.append((request.value(forHTTPHeaderField: "Content-Range"), URLProtocolMock.body(of: request))) }
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
			let localURL = try makeLocalFile(content: "content")
			for testCase in cases {
				URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: testCase.statusCode)]

				let error = try await #require(throws: (any Error).self, "\(testCase.statusCode)") { try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
				#expect(String(describing: testCase.expectedError) == String(describing: error), "\(testCase.statusCode)")
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(testCase.statusCode)")
			}
		}

		@Test
		func downloadReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
		}

		@Test
		func uploadReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			URLProtocolMock.requestHandler = uploadPreparation() + [URLProtocolMock.handler(statusCode: 201, body: MicrosoftGraphCloudProviderTests.fileItem)]

			_ = try await provider.uploadFile(from: makeLocalFile(content: "content"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
		}

		// MARK: - Download URL

		/// The date comes from the metadata request, because the path lookup's item has none.
		@Test
		func downloadFromDownloadURL() async throws {
			let requests = RequestRecorder()
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem, onRequest: requests.record),
				URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItemWithDownloadURL, onRequest: requests.record),
				URLProtocolMock.handler(body: "content", onRequest: requests.record)
			]

			let metadata = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)

			#expect([
				URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/root:/file.txt:?$select=id,name,size,folder,fileSystemInfo,parentReference,remoteItem"),
				URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/F"),
				URL(string: MicrosoftGraphCloudProviderTests.downloadURL)
			] == requests.requests.map(\.url))
			#expect(requests.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
			#expect(try Data("content".utf8) == Data(contentsOf: localURL))
			#expect(Date(timeIntervalSince1970: 1_794_823_200) == metadata.lastModifiedDate)
		}

		@Test
		func downloadWithoutUsableDownloadURLGoesThroughGraph() async throws {
			for metadataBody in [MicrosoftGraphCloudProviderTests.fileItem, MicrosoftGraphCloudProviderTests.fileItemWithDownloadURL.replacingOccurrences(of: "https://", with: "http://")] {
				let provider = try MicrosoftGraphCloudProvider(client: .mocked())
				let requests = RequestRecorder()
				let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(body: MicrosoftGraphCloudProviderTests.fileItem),
					URLProtocolMock.handler(body: metadataBody),
					URLProtocolMock.handler(body: "content", onRequest: requests.record)
				]

				_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)

				#expect([URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/F/content")] == requests.requests.map(\.url), "\(metadataBody)")
				#expect(requests.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN", "\(metadataBody)")
				#expect(try Data("content".utf8) == Data(contentsOf: localURL), "\(metadataBody)")
			}
		}

		@Test
		func refusedDownloadURLFallsBackToGraph() async throws {
			let requests = RequestRecorder()
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
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
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
			URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(statusCode: 404), URLProtocolMock.handler(statusCode: 404)]

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func otherSuccessOfDownloadURLFailsWithoutFallback() async throws {
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
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

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: nil, onTaskCreation: nil)

			#expect(logCapture.messages.contains { $0.hasPrefix("--> GET https://content.example.com") }, "\(logCapture.joinedMessages)")
			#expect(!logCapture.joinedMessages.contains("SECRET"), "\(logCapture.joinedMessages)")
		}

		@Test
		func downloadFromDownloadURLReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try MicrosoftGraphCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)))
			URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
		}

		@Test
		func fallbackHandsOverNoTask() async throws {
			let taskHosts = OSAllocatedUnfairLock(initialState: [String?]())
			URLProtocolMock.requestHandler = directDownloadPreparation() + [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: "content")]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: nil, onTaskCreation: { task in
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

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: progress, onTaskCreation: nil)

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
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
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

		// MARK: - Requests

		@Test
		func testChildrenRequest() throws {
			let item = MicrosoftGraphItem(cloudPath: CloudPath("/test"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder, isRemoteItem: false)
			let request = try provider.childrenRequest(for: item)
			#expect(request.httpMethod == "GET")
			#expect(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/children?$top=100&$select=id,name,size,folder,fileSystemInfo,parentReference,remoteItem") == request.url)
			#expect(request.httpBody == nil)
		}

		@Test
		func testContentRequest() throws {
			let item = MicrosoftGraphItem(cloudPath: CloudPath("/test"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder, isRemoteItem: false)
			let request = try provider.contentRequest(for: item)
			#expect(request.httpMethod == "GET")
			#expect(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/content") == request.url)
			#expect(request.httpBody == nil)
		}

		@Test
		func testCreateUploadSessionRequest() throws {
			let parentItem = MicrosoftGraphItem(cloudPath: CloudPath("/testFolder"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder, isRemoteItem: false)
			let request = try provider.createUploadSessionRequest(for: parentItem, with: "Test.txt")
			#expect(request.httpMethod == "POST")
			#expect(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier:/Test.txt:/createUploadSession") == request.url)
			#expect(request.httpBody == nil)
		}

		@Test
		func testFileChunkUploadRequest() throws {
			let uploadURL = try #require(URL(string: "example.com"))
			let chunkLength = 26
			let totalLength = 128
			let request = provider.fileChunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: 0, totalLength: totalLength)
			#expect(request.httpMethod == "PUT")
			#expect(request.value(forHTTPHeaderField: "Content-Length") == "26")
			#expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-25/128")
			#expect(uploadURL == request.url)
		}

		@Test
		func fileChunkUploadRequestWithOffset() throws {
			let uploadURL = try #require(URL(string: "example.com"))
			let chunkLength = 26
			let totalLength = 128
			let request = provider.fileChunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: 26, totalLength: totalLength)
			#expect(request.httpMethod == "PUT")
			#expect(request.value(forHTTPHeaderField: "Content-Length") == "26")
			#expect(request.value(forHTTPHeaderField: "Content-Range") == "bytes 26-51/128")
			#expect(uploadURL == request.url)
		}

		@Test
		func testCreateFolderRequest() throws {
			let parentItem = MicrosoftGraphItem(cloudPath: CloudPath("/testFolder"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder, isRemoteItem: false)
			let expectedRequestBody = "{\"@odata.type\":\"#microsoft.graph.driveItem\",\"folder\":{},\"name\":\"subFolder\"}"
			let request = try provider.createFolderRequest(for: parentItem, with: "subFolder")
			#expect(request.httpMethod == "POST")
			#expect(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/children") == request.url)
			#expect(expectedRequestBody.data(using: .utf8) == request.httpBody)
		}

		@Test
		func testDeleteItemRequest() throws {
			let item = MicrosoftGraphItem(cloudPath: CloudPath("/test.txt"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .file, isRemoteItem: false)
			let request = try provider.deleteItemRequest(for: item)
			#expect(request.httpMethod == "DELETE")
			#expect(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier") == request.url)
			#expect(request.httpBody == nil)
		}

		@Test
		func testMoveItemRequest() throws {
			let item = MicrosoftGraphItem(cloudPath: CloudPath("/test.txt"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .file, isRemoteItem: false)
			let newParentItem = MicrosoftGraphItem(cloudPath: CloudPath("/Folder"), identifier: "TestIdentifier-Folder", driveIdentifier: nil, itemType: .folder, isRemoteItem: false)
			let targetCloudPath = CloudPath("/Folder/test.txt")
			let expectedRequestBody = "{\"@odata.type\":\"#microsoft.graph.driveItem\",\"name\":\"test.txt\",\"parentReference\":{\"id\":\"TestIdentifier-Folder\"}}"
			let request = try provider.moveItemRequest(for: item, with: newParentItem, targetCloudPath: targetCloudPath)
			#expect(request.httpMethod == "PATCH")
			#expect(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier") == request.url)
			#expect(expectedRequestBody.data(using: .utf8) == request.httpBody)
		}

		// MARK: - Helpers

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
