//
//  PCloudCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class PCloudCloudProviderTests {
		private let provider: PCloudCloudProvider
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.provider = try PCloudCloudProvider(client: .mocked())
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

		// MARK: - Error Mapping

		/// An unmapped code, e.g., a connection that broke during an upload, doesn't ask for a new login.
		@Test
		func uploadFileWithUnmappedCodeThrowsAPIError() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0)),
				URLProtocolMock.handler(body: PCloudMockResponse.result(2041))
			]

			await #expect(throws: PCloudError.apiError(code: 2041, message: "Error 2041.")) { try await provider.uploadFile(from: makeLocalFile(), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
		}

		/// Each API error code that a method maps, scripted after the listings that resolve its paths.
		@Test
		func mapsAPIErrorCodesPerMethod() async throws {
			let localURL = try makeLocalFile()
			let downloadURL = tmpDirURL.appendingPathComponent("download.txt")
			let rootWithFolder = PCloudProviderTestResponse.rootWithFolder
			let rootWithFile = PCloudProviderTestResponse.rootWithFile
			let cases = [
				ProviderCase(name: "stat", responses: [rootWithFile, PCloudMockResponse.result(2009)], operation: { _ = try await $0.fetchItemMetadata(at: CloudPath("/file.txt")) }, expected: CloudProviderError.itemNotFound),
				ProviderCase(name: "listfolder of an upload's parent", responses: [PCloudMockResponse.result(2005)], operation: { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }, expected: CloudProviderError.parentFolderDoesNotExist),
				ProviderCase(name: "listfolder of a folder", responses: [rootWithFolder, PCloudMockResponse.result(2005)], operation: { _ = try await $0.fetchItemMetadata(at: CloudPath("/folder")) }, expected: CloudProviderError.itemNotFound),
				ProviderCase(name: "listfolder of a listing", responses: [rootWithFolder, PCloudMockResponse.result(2005)], operation: { _ = try await $0.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil) }, expected: CloudProviderError.itemNotFound),
				ProviderCase(name: "listfolder of a path", responses: [rootWithFolder, PCloudMockResponse.result(2005)], operation: { _ = try await $0.fetchItemMetadata(at: CloudPath("/folder/file.txt")) }, expected: CloudProviderError.itemNotFound),
				ProviderCase(name: "listfolder of a collision check", responses: [rootWithFolder, PCloudMockResponse.result(2005)], operation: { try await $0.createFolder(at: CloudPath("/folder/sub")) }, expected: CloudProviderError.parentFolderDoesNotExist),
				ProviderCase(name: "getfilelink", responses: [rootWithFile, PCloudMockResponse.file(id: 5), PCloudMockResponse.result(2009)], operation: { _ = try await $0.downloadFile(from: CloudPath("/file.txt"), to: downloadURL, progress: nil, onTaskCreation: nil) }, expected: CloudProviderError.itemNotFound),
				ProviderCase(name: "deletefile", responses: [rootWithFile, PCloudMockResponse.result(2009)], operation: { try await $0.deleteFile(at: CloudPath("/file.txt")) }, expected: CloudProviderError.itemNotFound),
				ProviderCase(name: "deletefile 2003", responses: [rootWithFile, PCloudMockResponse.result(2003)], operation: { try await $0.deleteFile(at: CloudPath("/file.txt")) }, expected: CloudProviderError.deletionIncomplete),
				ProviderCase(name: "deletefolderrecursive", responses: [rootWithFolder, PCloudMockResponse.result(2005)], operation: { try await $0.deleteFolder(at: CloudPath("/folder")) }, expected: CloudProviderError.itemNotFound),
				ProviderCase(name: "deletefolderrecursive 2003", responses: [rootWithFolder, PCloudMockResponse.result(2003)], operation: { try await $0.deleteFolder(at: CloudPath("/folder")) }, expected: CloudProviderError.deletionIncomplete),
				ProviderCase(name: "deletefolderrecursive 2028", responses: [rootWithFolder, PCloudMockResponse.result(2028)], operation: { try await $0.deleteFolder(at: CloudPath("/folder")) }, expected: CloudProviderError.deletionIncomplete),
				ProviderCase(name: "createfolder 2004", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.result(2004)], operation: { try await $0.createFolder(at: CloudPath("/folder")) }, expected: CloudProviderError.itemAlreadyExists),
				ProviderCase(name: "createfolder 2002", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.result(2002)], operation: { try await $0.createFolder(at: CloudPath("/folder")) }, expected: CloudProviderError.parentFolderDoesNotExist),
				ProviderCase(name: "createfolder 2008", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.result(2008)], operation: { try await $0.createFolder(at: CloudPath("/folder")) }, expected: CloudProviderError.quotaInsufficient),
				ProviderCase(name: "uploadfile 2005", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.result(2005)], operation: { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }, expected: CloudProviderError.parentFolderDoesNotExist),
				ProviderCase(name: "uploadfile 2008", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.result(2008)], operation: { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }, expected: CloudProviderError.quotaInsufficient),
				ProviderCase(name: "renamefile 2005", responses: [rootWithFile, rootWithFile, PCloudMockResponse.result(2005)], operation: { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) }, expected: CloudProviderError.parentFolderDoesNotExist),
				ProviderCase(name: "renamefile 2009", responses: [rootWithFile, rootWithFile, PCloudMockResponse.result(2009)], operation: { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) }, expected: CloudProviderError.itemNotFound),
				ProviderCase(name: "renamefile 2008", responses: [rootWithFile, rootWithFile, PCloudMockResponse.result(2008)], operation: { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) }, expected: CloudProviderError.quotaInsufficient),
				ProviderCase(name: "renamefolder 2004", responses: [rootWithFolder, rootWithFolder, PCloudMockResponse.result(2004)], operation: { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) }, expected: CloudProviderError.itemAlreadyExists),
				ProviderCase(name: "renamefolder 2005", responses: [rootWithFolder, rootWithFolder, PCloudMockResponse.result(2005)], operation: { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) }, expected: CloudProviderError.itemNotFound),
				ProviderCase(name: "renamefolder 2008", responses: [rootWithFolder, rootWithFolder, PCloudMockResponse.result(2008)], operation: { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) }, expected: CloudProviderError.quotaInsufficient)
			]

			try await expectErrorsConsumingAllResponses(cases)
		}

		/// The content host's message could name the file link's path, so the failure logs show only the code, while the thrown error keeps the message.
		@Test
		func failedDownloadThrowsErrorOfResultAndLeavesNoFileOrMessageInLog() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
			URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(statusCode: 410, body: #"{"result":2009,"error":"Cannot serve /SECRETPATH/file.txt"}"#)]

			await #expect(throws: PCloudError.apiError(code: 2009, message: "Cannot serve /SECRETPATH/file.txt")) { try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil) }
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
			let messages = logCapture.messages
			#expect(messages.filter { $0.hasPrefix("PCloudClient: file link download failed with ") } == ["PCloudClient: file link download failed with pCloud API error 2009"])
			#expect(messages.filter { $0.hasPrefix("PCloudCloudProvider: downloadFileLink(") && $0.hasSuffix(" failed with error: pCloud API error 2009") }.count == 1)
			#expect(!logCapture.joinedMessages.contains("SECRETPATH"), "\(logCapture.joinedMessages)")
		}

		/// The client's failure log keeps the code of a rejected login, which the provider throws as `unauthorized`.
		@Test
		func downloadRejectedForLoginThrowsUnauthorizedAndLogsCode() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(statusCode: 403, body: PCloudMockResponse.result(2094))]

			await #expect(throws: CloudProviderError.unauthorized) { try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: nil, onTaskCreation: nil) }
			#expect(logCapture.messages.filter { $0.hasPrefix("PCloudClient: file link download failed with ") } == ["PCloudClient: file link download failed with pCloud API error 2094"])
		}

		/// Only `deletefolderrecursive` documents 2028 (active shares), so `deletefile` passes it through.
		@Test
		func deleteFileWithActiveSharesCodeThrowsAPIError() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFile), URLProtocolMock.handler(body: PCloudMockResponse.result(2028))]

			await #expect(throws: PCloudError.apiError(code: 2028, message: "Error 2028.")) { try await provider.deleteFile(at: CloudPath("/file.txt")) }
		}

		// MARK: - Metadata

		@Test
		func fetchItemMetadataConvertsFileAndFolder() async throws {
			let root = PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "file.txt"), PCloudMockResponse.folderEntry(id: 3, name: "folder")])
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: root),
				URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5)),
				URLProtocolMock.handler(body: root),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3))
			]

			let fileMetadata = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))
			let folderMetadata = try await provider.fetchItemMetadata(at: CloudPath("/folder"))

			PCloudProviderTestResponse.assertMetadata(fileMetadata, name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, size: 7)
			PCloudProviderTestResponse.assertMetadata(folderMetadata, name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, size: nil)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func fetchItemListConvertsAndCachesChildren() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "file.txt"), PCloudMockResponse.folderEntry(id: 3, name: "folder")])),
				URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5))
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			#expect(itemList.items.count == 2)
			#expect(itemList.nextPageToken == nil)
			PCloudProviderTestResponse.assertMetadata(itemList.items[0], name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, size: 7)
			PCloudProviderTestResponse.assertMetadata(itemList.items[1], name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, size: nil)
			#expect(URLProtocolMock.requestHandler.isEmpty, "The listed file was resolved through another listing")
		}

		@Test
		func incompleteMetadataThrowsUnexpectedContent() async throws {
			let cases = [
				ProviderCase(name: "listing without contents", responses: [#"{"result":0,"metadata":{"isfolder":true,"name":"","folderid":0,"modified":1792056600}}"#], operation: { _ = try await $0.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }, expected: PCloudError.unexpectedContent),
				ProviderCase(name: "child without identifier", responses: [#"{"result":0,"metadata":{"isfolder":true,"name":"","folderid":0,"modified":1792056600,"contents":[{"isfolder":false,"name":"file.txt","modified":1792056600,"size":7}]}}"#], operation: { _ = try await $0.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }, expected: PCloudError.unexpectedContent),
				ProviderCase(name: "file without size", responses: [PCloudProviderTestResponse.rootWithFile, #"{"result":0,"metadata":{"isfolder":false,"name":"file.txt","fileid":5,"modified":1792056600}}"#], operation: { _ = try await $0.fetchItemMetadata(at: CloudPath("/file.txt")) }, expected: PCloudError.unexpectedContent),
				ProviderCase(name: "identifier above Int64.max", responses: [PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: UInt64(Int64.max) + 1, name: "file.txt")])], operation: { _ = try await $0.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }, expected: PCloudError.unexpectedContent)
			]

			for testCase in cases {
				let provider = try PCloudCloudProvider(client: .mocked())
				URLProtocolMock.requestHandler = testCase.responses.map { URLProtocolMock.handler(body: $0) }

				await #expect(throws: testCase.expected, "\(testCase.name)") { try await testCase.operation(provider) }
			}
		}

		@Test
		func listingWithNullContentsIsOnlyFolderMetadata() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 3, name: "folder")])),
				URLProtocolMock.handler(body: PCloudProviderTestResponse.folderWithNullContents),
				URLProtocolMock.handler(body: PCloudProviderTestResponse.folderWithNullContents)
			]

			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/folder"))
			await #expect(throws: PCloudError.unexpectedContent) { try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil) }

			PCloudProviderTestResponse.assertMetadata(metadata, name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, size: nil)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func looksUpFolderByNameWithoutDecodingLaterChildren() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 1, name: "a.txt"), PCloudMockResponse.folderEntry(id: 2, name: "b"), #"{"isfolder":false,"name":"c.txt"}"#])),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 2, name: "b"), onRequest: requests.record)
			]

			_ = try await provider.fetchItemMetadata(at: CloudPath("/b"))

			#expect(requests.requests.first.map(URLProtocolMock.formParameters)?["folderid"] == "2")
		}

		@Test(arguments: [false, true])
		func lookupPrefersFolderOfSameName(fileFirst: Bool) async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFileAndFolderNamedX(fileFirst: fileFirst)),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3, name: "x"), onRequest: requests.record)
			]

			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/x"))

			PCloudProviderTestResponse.assertMetadata(metadata, name: "x", cloudPath: CloudPath("/x"), itemType: .folder, size: nil)
			#expect(requests.requests.first.map(URLProtocolMock.formParameters)?["folderid"] == "3")
		}

		@Test(arguments: [false, true])
		func listingCachesFolderOfSameName(fileFirst: Bool) async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFileAndFolderNamedX(fileFirst: fileFirst)),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3, name: "x"), onRequest: requests.record)
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			_ = try await provider.fetchItemMetadata(at: CloudPath("/x"))

			#expect(itemList.items.map(\.itemType) == (fileFirst ? [.file, .folder] : [.folder, .file]))
			#expect(requests.requests.first.map(URLProtocolMock.formParameters)?["folderid"] == "3")
		}

		@Test
		func listingReplacesCachedFolderWithFileOfSameName() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 3, name: "x")])),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "x")])),
				URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5, name: "x"), onRequest: requests.record)
			]

			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			_ = try await provider.fetchItemMetadata(at: CloudPath("/x"))

			#expect(requests.requests.first.map(URLProtocolMock.formParameters)?["fileid"] == "5")
		}

		@Test
		func failedListingStillCachesFolderOfSameName() async throws {
			let requests = RequestRecorder()
			let undecodableChild = #"{"isfolder":false,"name":"c.txt"}"#
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 3, name: "x"), PCloudMockResponse.fileEntry(id: 5, name: "x"), undecodableChild])),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3, name: "x"), onRequest: requests.record)
			]

			await #expect(throws: (any Error).self) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			_ = try await provider.fetchItemMetadata(at: CloudPath("/x"))

			#expect(requests.requests.first.map(URLProtocolMock.formParameters)?["folderid"] == "3")
		}

		@Test
		func createFolderFindsCollidingFolder() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 1, name: "a.txt"), PCloudMockResponse.folderEntry(id: 2, name: "b"), PCloudMockResponse.fileEntry(id: 3, name: "c.txt")])),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 4, name: "b"))
			]

			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.createFolder(at: CloudPath("/b")) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func uploadFileOntoFileAndFolderOfSameNameThrowsItemAlreadyExists() async throws {
			let localURL = try makeLocalFile()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFileAndFolderNamedX(fileFirst: true))]

			await #expect(throws: CloudProviderError.itemAlreadyExists) { _ = try await provider.uploadFile(from: localURL, to: CloudPath("/x"), replaceExisting: true, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// pCloud numbers files and folders separately, so a file's identifier sent as a folder's, or the reverse, would name another item. Its lookups list the whole folder, so the missing source's listing holds the existing target.
		@Test
		func mutationGuardsSendNoRequestBeyondResolution() async throws {
			let rootWithFile = PCloudProviderTestResponse.rootWithFile
			let cases = try MutationGuardCases.make(localURL: makeLocalFile(), file: URLProtocolMock.handler(body: rootWithFile), folder: URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFolder), missing: URLProtocolMock.handler(body: rootWithFile))

			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { try PCloudCloudProvider(client: .mocked()) }
			try await expectErrorsConsumingAllResponses([
				ProviderCase(name: "lookup below a file", responses: [rootWithFile], operation: { _ = try await $0.fetchItemMetadata(at: CloudPath("/file.txt/sub")) }, expected: CloudProviderError.itemNotFound)
			])
		}

		/// The folder lookup prefers the folder of the name even though the cache holds the file of that name.
		@Test
		func replacingUploadOntoCachedFileWithFolderOfSameNameThrowsItemAlreadyExists() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "x")])),
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFileAndFolderNamedX(fileFirst: true))
			]
			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)

			await #expect(throws: CloudProviderError.itemAlreadyExists) { _ = try await provider.uploadFile(from: makeLocalFile(), to: CloudPath("/x"), replaceExisting: true, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A mutation's request is its commit point, so it runs outside the task, whose cancellation it doesn't see.
		@Test
		func cancelledMutationsSendTheirRequestsOutsideCancelledTask() async throws {
			let rootWithFile = PCloudProviderTestResponse.rootWithFile
			let rootWithFolder = PCloudProviderTestResponse.rootWithFolder
			let cases = [
				MutationRequestCase(name: "createFolder", responses: [PCloudMockResponse.folder(id: 0), PCloudMockResponse.folder(id: 3)], operation: { try await $0.createFolder(at: CloudPath("/folder")) }),
				MutationRequestCase(name: "deleteFile", responses: [rootWithFile, #"{"result":0}"#], operation: { try await $0.deleteFile(at: CloudPath("/file.txt")) }),
				MutationRequestCase(name: "deleteFolder", responses: [rootWithFolder, #"{"result":0}"#], operation: { try await $0.deleteFolder(at: CloudPath("/folder")) }),
				MutationRequestCase(name: "moveFile", responses: [rootWithFile, rootWithFile, PCloudMockResponse.file(id: 5, name: "renamed.txt")], operation: { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) }),
				MutationRequestCase(name: "moveFolder", responses: [rootWithFolder, rootWithFolder, PCloudMockResponse.folder(id: 3, name: "renamed")], operation: { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed")) })
			]
			for testCase in cases {
				let tokenSource = PausingTokenSource(pausedCall: testCase.responses.count)
				let provider = try PCloudCloudProvider(client: .mocked(tokenSource: tokenSource))
				URLProtocolMock.requestHandler = testCase.responses.map { URLProtocolMock.handler(body: $0) }

				let task = Task {
					try await testCase.operation(provider)
				}
				await tokenSource.entered.wait()
				task.cancel()
				tokenSource.resume()

				try await cancellingValue(of: task)
				#expect(tokenSource.wasCancelled == false, "\(testCase.name)")
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(testCase.name)")
			}
		}

		// MARK: - Paging

		@Test
		func fetchItemListPagesThroughSnapshotWithoutRequests() async throws {
			let provider = try PCloudCloudProvider(client: .mocked(), maxPageSize: 2)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFiles(["a", "b", "c", "d", "e"]))]

			let firstPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			let secondPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: #require(firstPage.nextPageToken) as String)
			let thirdPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: #require(secondPage.nextPageToken) as String)

			#expect(firstPage.items.map(\.name) == ["a", "b"])
			#expect(secondPage.items.map(\.name) == ["c", "d"])
			#expect(thirdPage.items.map(\.name) == ["e"])
			#expect(thirdPage.nextPageToken == nil)
			PCloudProviderTestResponse.assertMetadata(thirdPage.items[0], name: "e", cloudPath: CloudPath("/e"), itemType: .file, size: 7)
		}

		/// An item whose name is no single path component gets no snapshot position, because a gap in the positions would drop a later item from the pages. It gets no cached identifier either, so that it shadows no path and doesn't replace the cached root.
		@Test
		func listingSkipsNamesThatAreNoSinglePathComponent() async throws {
			let provider = try PCloudCloudProvider(client: .mocked(), maxPageSize: 2)
			let requests = RequestRecorder()
			let root = PCloudProviderTestResponse.rootWithFiles(["a", "b", ".", "x/y", "c"])
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: root), URLProtocolMock.handler(body: root, onRequest: requests.record)]

			let firstPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			let secondPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: #require(firstPage.nextPageToken) as String)
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/x/y")) }

			#expect(firstPage.items.map(\.name) == ["a", "b"])
			#expect(secondPage.items.map(\.name) == ["c"])
			#expect(secondPage.nextPageToken == nil)
			#expect(requests.requests.map { URLProtocolMock.formParameters(of: $0)["folderid"] } == ["0"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func interleavedListingsOfSameFolderSeeTheirOwnItems() async throws {
			let provider = try PCloudCloudProvider(client: .mocked(), maxPageSize: 2)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFiles(["a", "b", "c"])),
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFiles(["x", "y", "z"]))
			]

			let firstListing = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			let secondListing = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			let firstListingRest = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: #require(firstListing.nextPageToken) as String)
			let secondListingRest = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: #require(secondListing.nextPageToken) as String)

			#expect((firstListing.items + firstListingRest.items).map(\.name) == ["a", "b", "c"])
			#expect((secondListing.items + secondListingRest.items).map(\.name) == ["x", "y", "z"])
		}

		@Test
		func unpublishedPageTokensThrowPageTokenInvalid() async throws {
			let provider = try PCloudCloudProvider(client: .mocked(), maxPageSize: 1)
			let listings = DirectoryContentDBCache.retainedSnapshotsPerFolder + 1
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 3, name: "folder"), PCloudMockResponse.fileEntry(id: 5, name: "file.txt")])), count: listings)
			var pageTokens = [String]()
			for _ in 0 ..< listings {
				let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
				try pageTokens.append(#require(itemList.nextPageToken))
			}

			let cases = [(CloudPath("/folder"), pageTokens[listings - 1]), (CloudPath("/"), "invalid"), (CloudPath("/"), pageTokens[0])]
			for (cloudPath, pageToken) in cases {
				await #expect(throws: CloudProviderError.pageTokenInvalid, "\(pageToken)") { try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: pageToken) }
			}
			_ = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: pageTokens[1])
		}

		@Test
		func temporaryDirectoryLiesInProcessFolder() throws {
			let provider = try PCloudCloudProvider(client: .mocked())

			#expect(try ProcessTemporaryDirectory.shared.directoryURL().path == provider.tmpDirURL.deletingLastPathComponent().path)
		}

		@Test
		func listingsLeaveNoFilesAndReleaseRemovesTemporaryDirectory() async throws {
			var provider: PCloudCloudProvider? = try PCloudCloudProvider(client: .mocked())
			let tmpDirURL = try #require(provider?.tmpDirURL)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFiles(["a"])), URLProtocolMock.handler(body: PCloudMockResponse.result(2005))]

			_ = try await provider?.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider?.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
			#expect(try FileManager.default.contentsOfDirectory(atPath: tmpDirURL.path).filter { !$0.hasPrefix("db.sqlite") } == [])

			provider = nil
			#expect(!FileManager.default.fileExists(atPath: tmpDirURL.path))
		}

		@Test
		func failedFillLeavesNoRows() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "a.txt"), #"{"isfolder":false,"name":"b.txt","modified":1792056600,"size":7}"#]))]

			await #expect(throws: PCloudError.unexpectedContent) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }

			try assertDirectoryContentCacheIsEmpty(provider.directoryContentCache)
		}

		@Test
		func cancelledFillStopsAtNextChild() async throws {
			let cache = try SaveCountingDirectoryContentCache(cache: DirectoryContentDBCache(dbWriter: DatabaseQueue(), maxPageSize: .max)) { count in
				if count == 1 {
					withUnsafeCurrentTask { $0?.cancel() }
				}
			}
			let provider = try PCloudCloudProvider(client: .mocked(), directoryContentCache: cache)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFiles(["a", "b", "c"]))]

			let listing = Task {
				try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: listing) }

			#expect(cache.saveCount == 1)
			try assertDirectoryContentCacheIsEmpty(cache.cache)
		}

		@Test
		func fetchItemListOfFileThrowsItemTypeMismatchWithoutListing() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFile),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 5))
			]

			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.fetchItemList(forFolderAt: CloudPath("/file.txt"), withPageToken: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		// MARK: - Logging

		@Test
		func downloadFileLeavesNoFileLinkInLog() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(body: "content")]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: nil, onTaskCreation: nil)

			let log = logCapture.joinedMessages
			for secret in [PCloudCredential.stubAccessToken, PCloudMockResponse.link.path, PCloudMockResponse.link.dwltag] {
				#expect(!log.contains(secret), "\(secret) in \(log)")
			}
		}

		/// The failure is logged once, with pCloud's code before it is mapped.
		@Test
		func refusedDeleteFileLogsRawCodeOnce() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFile), URLProtocolMock.handler(body: PCloudMockResponse.result(2003))]

			await #expect(throws: CloudProviderError.deletionIncomplete) { try await provider.deleteFile(at: CloudPath("/file.txt")) }

			let failures = logCapture.messages.filter { $0.hasPrefix("PCloudCloudProvider: deleteFile(for: 5) failed with error:") }
			#expect(failures.count == 1, "\(failures)")
			#expect(failures.first?.contains("2003") == true, "\(failures)")
		}

		@Test
		func deleteFileOfFolderLogsTypeMismatchOnce() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFolder)]

			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.deleteFile(at: CloudPath("/folder")) }

			#expect(logCapture.messages.filter { $0.hasPrefix("PCloudCloudProvider: deleteFile(at: /folder) failed with error:") }.count == 1)
		}

		// MARK: - Transfers

		@Test
		func downloadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider = provider
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
			let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
			let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
			URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(body: "content", onRequest: { _ in
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
		func uploadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider = provider
			let localURL = try makeLocalFile()
			let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
			let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0)),
				URLProtocolMock.handler(body: PCloudMockResponse.uploadedFile(id: 5), onRequest: { _ in
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
			#expect(CloudPath("/file.txt") == metadata.cloudPath)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadFileWithCancellationDuringOnTaskCreation() async throws {
			let provider = provider
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
			URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(body: "content")]

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
		func uploadFileWithCancellationDuringOnTaskCreation() async throws {
			let provider = provider
			let localURL = try makeLocalFile()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0)),
				URLProtocolMock.handler(body: PCloudMockResponse.uploadedFile(id: 5))
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
		func downloadFileReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try PCloudCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions, excluding: PCloudProviderTestResponse.isListing)))
			URLProtocolMock.requestHandler = PCloudProviderTestResponse.downloadPreparation + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("file.txt"), progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
			#expect(progress.fractionCompleted == 1)
		}

		@Test
		func uploadFileReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try PCloudCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions, excluding: PCloudProviderTestResponse.isListing)))
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0)),
				URLProtocolMock.handler(body: PCloudMockResponse.uploadedFile(id: 5))
			]

			_ = try await provider.uploadFile(from: makeLocalFile(), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
			#expect(progress.fractionCompleted == 1)
		}

		// MARK: - Late Responses

		/// The listing's response names the file at the path that a rename freed and a new folder took, so it must not cache the file there, or deleting the folder would delete the renamed file.
		@Test
		func lateListingKeepsChildOutOfPathThatChanged() async throws {
			let tokenSource = PausingTokenSource(pausedCall: 2)
			let provider = try PCloudCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			let rootWithFile = URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFile)
			URLProtocolMock.requestHandler = [
				rootWithFile,
				rootWithFile,
				URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5, name: "renamed.txt")),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "renamed.txt")])),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 8, name: "file.txt")),
				rootWithFile,
				URLProtocolMock.handler(body: #"{"result":0}"#, onRequest: requests.record)
			]
			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)

			let itemList = try await runningWhilePaused(tokenSource) {
				try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)
			} intervening: {
				try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))
				try await provider.createFolder(at: CloudPath("/file.txt"))
			}
			try await provider.deleteFolder(at: CloudPath("/file.txt"))

			#expect(itemList.items.map(\.name) == ["file.txt"])
			#expect(requests.requests.map { URLProtocolMock.formParameters(of: $0)["folderid"] } == ["8"])
		}

		/// The listed folder moved and a new folder took its path. No record names the child's path, so only the parent check keeps the moved folder's child out of the new folder.
		@Test
		func lateListingOfMovedFolderKeepsChildOut() async throws {
			let tokenSource = PausingTokenSource(pausedCall: 2)
			let provider = try PCloudCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFolder),
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFolder),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3, name: "moved")),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 3, name: "moved")])),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 8, name: "folder")),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3, contents: [PCloudMockResponse.fileEntry(id: 5, name: "x")])),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 8), onRequest: requests.record)
			]

			_ = try await runningWhilePaused(tokenSource) {
				try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)
			} intervening: {
				try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/moved"))
				try await provider.createFolder(at: CloudPath("/folder"))
			}
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.deleteFile(at: CloudPath("/folder/x")) }

			#expect(requests.requests.map { URLProtocolMock.formParameters(of: $0)["folderid"] } == ["8"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The listing's mark precedes the lookup of its folder, so a change during that lookup refuses the listing's rows.
		@Test
		func listingWhoseFolderLookupSeesChangeKeepsChildOut() async throws {
			let tokenSource = PausingTokenSource(pausedCall: 1)
			let provider = try PCloudCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFolder),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3)),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 8, name: "new")),
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFolder),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3, contents: [PCloudMockResponse.folderEntry(id: 9, name: "new")])),
				URLProtocolMock.handler(body: #"{"result":0}"#, onRequest: requests.record)
			]

			_ = try await runningWhilePaused(tokenSource) {
				try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)
			} intervening: {
				try await provider.createFolder(at: CloudPath("/folder/new"))
			}
			try await provider.deleteFolder(at: CloudPath("/folder/new"))

			#expect(requests.requests.map { URLProtocolMock.formParameters(of: $0)["folderid"] } == ["8"])
		}

		/// A file and a folder of one name make the listing write its folders a second time, even if a later child fails the fill. That second write must not bring back a folder that was renamed meanwhile.
		@Test(arguments: [false, true])
		func replayOfFoldersKeepsRenamedFolderOut(fillFails: Bool) async throws {
			let tokenSource = PausingTokenSource(pausedCall: 2)
			let provider = try PCloudCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			let rootWithY = PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 7, name: "y")])
			let childWithoutIdentifier = #"{"isfolder":false,"name":"broken","modified":1792056600,"size":7}"#
			let lateChildren = [PCloudMockResponse.folderEntry(id: 7, name: "y"), PCloudMockResponse.folderEntry(id: 3, name: "x"), PCloudMockResponse.fileEntry(id: 5, name: "x")] + (fillFails ? [childWithoutIdentifier] : [])
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: rootWithY),
				URLProtocolMock.handler(body: rootWithY),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 7, name: "z")),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 7, name: "z")])),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 8, name: "y")),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: lateChildren)),
				URLProtocolMock.handler(body: #"{"result":0}"#, onRequest: requests.record)
			]
			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)

			try await runningWhilePaused(tokenSource) {
				do {
					_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)
					#expect(!fillFails)
				} catch PCloudError.unexpectedContent {
					#expect(fillFails)
				}
			} intervening: {
				try await provider.moveFolder(from: CloudPath("/y"), to: CloudPath("/z"))
				try await provider.createFolder(at: CloudPath("/y"))
			}
			try await provider.deleteFolder(at: CloudPath("/y"))

			#expect(requests.requests.map { URLProtocolMock.formParameters(of: $0)["folderid"] } == ["8"])
		}

		/// The listed folder moves away and a new folder takes its path while the listing fills, after a file overwrote the folder of its name. No record names the children's paths, so only the parent check keeps the second write of the folders out of the new folder.
		@Test
		func replayOfFoldersKeepsChildrenOutOfReplacedFolder() async throws {
			let overwritten = TestSignal("file overwrote the folder of its name")
			let replaced = DispatchSemaphore(value: 0)
			let cache = try SaveCountingDirectoryContentCache(cache: DirectoryContentDBCache(dbWriter: DatabaseQueue(), maxPageSize: .max)) { count in
				guard count == 3 else {
					return
				}
				overwritten.fulfill()
				if replaced.wait(timeout: testWaitDeadline()) == .timedOut {
					Issue.record("The listed folder wasn't replaced while the listing filled")
				}
			}
			let provider = try PCloudCloudProvider(client: .mocked(), directoryContentCache: cache)
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFolder),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3, contents: [PCloudMockResponse.folderEntry(id: 7, name: "y"), PCloudMockResponse.folderEntry(id: 4, name: "x"), PCloudMockResponse.fileEntry(id: 5, name: "x")])),
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFolder),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3, name: "moved")),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 3, name: "moved")])),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 8, name: "folder")),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 8), onRequest: requests.record)
			]
			let listing = Task {
				try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)
			}
			await overwritten.wait()
			do {
				try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/moved"))
				try await provider.createFolder(at: CloudPath("/folder"))
			} catch {
				replaced.signal()
				_ = try? await listing.value
				throw error
			}
			replaced.signal()
			_ = try await listing.value

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.deleteFolder(at: CloudPath("/folder/y")) }

			#expect(requests.requests.map { URLProtocolMock.formParameters(of: $0)["folderid"] } == ["8"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test(arguments: LateMutationKind.allCases)
		func lateMutationResponseLeavesMovedAwayTargetUncached(kind: LateMutationKind) async throws {
			let testCase = try lateMutationCase(kind)
			let tokenSource = PausingTokenSource(pausedCall: testCase.preparation.count + 1)
			let provider = try PCloudCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = testCase.responses + [URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0), onRequest: requests.record)]

			try await runningWhilePaused(tokenSource) {
				try await testCase.perform(on: provider)
			} intervening: {
				try await testCase.rename(on: provider)
			}

			await testCase.expectTargetIsLookedUp(on: provider, requests: requests, lookupPath: "/listfolder")
		}

		/// The item was deleted while its metadata was on the way, so the late response must not bring its row back.
		@Test(arguments: [false, true])
		func lateMetadataLeavesInvalidatedRowAlone(isDownload: Bool) async throws {
			let tokenSource = PausingTokenSource(pausedCall: 2)
			let provider = try PCloudCloudProvider(client: .mocked(tokenSource: tokenSource))
			let localURL = tmpDirURL.appendingPathComponent("download.txt")
			let requests = RequestRecorder()
			let transfer = isDownload ? [URLProtocolMock.handler(body: PCloudMockResponse.fileLink()), URLProtocolMock.handler(body: "content")] : []
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFile),
				URLProtocolMock.handler(body: #"{"result":0}"#),
				URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5))
			] + transfer + [URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0), onRequest: requests.record)]
			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)

			try await runningWhilePaused(tokenSource) {
				if isDownload {
					_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)
				} else {
					_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))
				}
			} intervening: {
				try await provider.deleteFile(at: CloudPath("/file.txt"))
			}
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/file.txt")) }

			#expect(requests.requests.map(\.url?.path) == ["/listfolder"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A folder's metadata comes from its listing, which is a request of its own kind.
		@Test
		func lateFolderMetadataLeavesInvalidatedRowAlone() async throws {
			let tokenSource = PausingTokenSource(pausedCall: 2)
			let provider = try PCloudCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFolder),
				URLProtocolMock.handler(body: #"{"result":0}"#),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3)),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0), onRequest: requests.record)
			]
			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)

			_ = try await runningWhilePaused(tokenSource) {
				try await provider.fetchItemMetadata(at: CloudPath("/folder"))
			} intervening: {
				try await provider.deleteFolder(at: CloudPath("/folder"))
			}
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/folder")) }

			#expect(requests.requests.map { URLProtocolMock.formParameters(of: $0)["folderid"] } == ["0"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func metadataReadOfColdPathWarmsCache() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: PCloudProviderTestResponse.rootWithFile),
				URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5)),
				URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5))
			]

			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// pCloud may have applied the move, so the item's rows go although the response is unusable, and a listing that began before the move can't cache the item that the target held.
		@Test(arguments: [
			("{", false),
			(#"{"result":0,"metadata":{"isfolder":false,"name":"b","modified":1792056600,"size":7}}"#, false),
			(PCloudMockResponse.file(id: UInt64(Int64.max) + 1, name: "b"), false),
			("{", true),
			(#"{"result":0,"metadata":{"isfolder":true,"name":"b","modified":1792056600}}"#, true),
			(PCloudMockResponse.folder(id: UInt64(Int64.max) + 1, name: "b"), true)
		])
		func moveWithUnusableResponseEvictsItemAndRefusesOlderListing(body: String, isFolder: Bool) async throws {
			let tokenSource = PausingTokenSource(pausedCall: 2)
			let provider = try PCloudCloudProvider(client: .mocked(tokenSource: tokenSource))
			let requests = RequestRecorder()
			let entry: (UInt64, String) -> String = { id, name in
				isFolder ? PCloudMockResponse.folderEntry(id: id, name: name) : PCloudMockResponse.fileEntry(id: id, name: name)
			}
			let root = PCloudMockResponse.folder(id: 0, contents: [entry(5, "a"), entry(5, "alias")])
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: root),
				URLProtocolMock.handler(body: root),
				URLProtocolMock.handler(body: body),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [entry(9, "b")])),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0), onRequest: requests.record),
				URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [entry(5, "b")])),
				URLProtocolMock.handler(body: #"{"result":0}"#, onRequest: requests.record)
			]
			_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)

			_ = try await runningWhilePaused(tokenSource) {
				try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)
			} intervening: {
				await #expect(throws: PCloudError.unexpectedContent) {
					if isFolder {
						try await provider.moveFolder(from: CloudPath("/a"), to: CloudPath("/b"))
					} else {
						try await provider.moveFile(from: CloudPath("/a"), to: CloudPath("/b"))
					}
				}
			}
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/alias")) }
			if isFolder {
				try await provider.deleteFolder(at: CloudPath("/b"))
			} else {
				try await provider.deleteFile(at: CloudPath("/b"))
			}

			#expect(requests.requests.map(\.url?.path) == ["/listfolder", isFolder ? "/deletefolderrecursive" : "/deletefile"])
			#expect(requests.requests.last.map { URLProtocolMock.formParameters(of: $0)[isFolder ? "folderid" : "fileid"] } == "5")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Helpers

		/// Runs `operation` until its request is paused at its login, runs `intervening` meanwhile, and then lets the request go on, so that its response is processed after `intervening`.
		private func runningWhilePaused<Value: Sendable>(_ tokenSource: PausingTokenSource, _ operation: @escaping @Sendable () async throws -> Value, intervening: () async throws -> Void) async throws -> Value {
			let task = Task {
				try await operation()
			}
			await tokenSource.entered.wait()
			do {
				try await intervening()
			} catch {
				tokenSource.resume()
				_ = try? await cancellingValue(of: task)
				throw error
			}
			tokenSource.resume()
			return try await cancellingValue(of: task)
		}

		private func lateMutationCase(_ kind: LateMutationKind) throws -> LateMutationCase {
			let isFolder = kind == .createFolder
			let entry: (String) -> String = { name in
				isFolder ? PCloudMockResponse.folderEntry(id: 8, name: name) : PCloudMockResponse.fileEntry(id: 8, name: name)
			}
			let result: (String) -> String = { name in
				isFolder ? PCloudMockResponse.folder(id: 8, name: name) : PCloudMockResponse.file(id: 8, name: name)
			}
			let source = URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [entry("src")]))
			let atTarget = URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0, contents: [entry("new")]))
			let mutationBody = kind == .upload ? PCloudMockResponse.uploadedFile(id: 8, name: "new") : result("new")
			return try LateMutationCase(kind: kind, localURL: makeLocalFile(), preparation: kind == .move ? [source, source] : [URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0))], renameResponses: [atTarget, atTarget, URLProtocolMock.handler(body: result("moved"))], mutationResponses: [URLProtocolMock.handler(body: mutationBody)])
		}

		private func assertTransferProgress(_ fractions: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
			#expect(fractions.count == 1, "Unexpected number of transfer tasks", sourceLocation: sourceLocation)
			#expect((fractions.first ?? 0) > 0.5, "The progress of the transfer task isn't part of the transfer's progress", sourceLocation: sourceLocation)
			#expect((fractions.first ?? 1) < 1, "The progress completed before the transfer returned", sourceLocation: sourceLocation)
		}

		private func makeLocalFile() throws -> URL {
			let localURL = tmpDirURL.appendingPathComponent("local.txt")
			try Data("content".utf8).write(to: localURL)
			return localURL
		}

		/// Runs each case on a provider of its own and expects its error and every scripted response to be consumed.
		private func expectErrorsConsumingAllResponses(_ cases: [ProviderCase<some Error & Equatable>], sourceLocation: SourceLocation = #_sourceLocation) async throws {
			for testCase in cases {
				let provider = try PCloudCloudProvider(client: .mocked())
				URLProtocolMock.requestHandler = testCase.responses.map { URLProtocolMock.handler(body: $0) }

				await #expect(throws: testCase.expected, "\(testCase.name)", sourceLocation: sourceLocation) { try await testCase.operation(provider) }
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(testCase.name)", sourceLocation: sourceLocation)
			}
		}
	}
}

/// A mutation whose request is the last of `responses`.
private struct MutationRequestCase: Sendable {
	let name: String
	let responses: [String]
	let operation: @Sendable (PCloudCloudProvider) async throws -> Void
}

private struct ProviderCase<Expected: Error & Equatable>: Sendable {
	let name: String
	let responses: [String]
	let operation: @Sendable (PCloudCloudProvider) async throws -> Void
	let expected: Expected
}

private enum PCloudProviderTestResponse {
	static let rootWithFile = PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.fileEntry(id: 5, name: "file.txt")])
	static let rootWithFolder = PCloudMockResponse.folder(id: 0, contents: [PCloudMockResponse.folderEntry(id: 3, name: "folder")])

	static let isListing: @Sendable (URLSessionTask) -> Bool = { $0.originalRequest?.url?.path == "/listfolder" }
	static let folderWithNullContents = #"{"result":0,"metadata":{"isfolder":true,"name":"folder","folderid":3,"modified":1792056600,"contents":null}}"#

	/// The root folder with a file of each name, whose identifiers count from 1.
	static func rootWithFiles(_ names: [String]) -> String {
		return PCloudMockResponse.folder(id: 0, contents: names.enumerated().map { PCloudMockResponse.fileEntry(id: UInt64($0 + 1), name: $1) })
	}

	/// The root folder with the file 5 and the folder 3, both named `x`, which pCloud allows in one folder.
	static func rootWithFileAndFolderNamedX(fileFirst: Bool) -> String {
		let file = PCloudMockResponse.fileEntry(id: 5, name: "x")
		let folder = PCloudMockResponse.folderEntry(id: 3, name: "x")
		return PCloudMockResponse.folder(id: 0, contents: fileFirst ? [file, folder] : [folder, file])
	}

	/// The listing, `stat` and `getfilelink` that precede the download of `/file.txt`.
	static var downloadPreparation: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
		return [
			URLProtocolMock.handler(body: rootWithFile),
			URLProtocolMock.handler(body: PCloudMockResponse.file(id: 5)),
			URLProtocolMock.handler(body: PCloudMockResponse.fileLink())
		]
	}

	static func assertMetadata(_ metadata: CloudItemMetadata, name: String, cloudPath: CloudPath, itemType: CloudItemType, size: Int?, sourceLocation: SourceLocation = #_sourceLocation) {
		#expect(name == metadata.name, sourceLocation: sourceLocation)
		#expect(cloudPath == metadata.cloudPath, sourceLocation: sourceLocation)
		#expect(itemType == metadata.itemType, sourceLocation: sourceLocation)
		#expect(Date(timeIntervalSince1970: 1_792_056_600) == metadata.lastModifiedDate, sourceLocation: sourceLocation)
		#expect(size == metadata.size, sourceLocation: sourceLocation)
	}
}

/// Hands out the stub login, and pauses the request of one call until the test resumes it, recording whether that request's task was cancelled then. A pCloud request reads its login inside its task.
private final class PausingTokenSource: PCloudTokenSource {
	let entered = TestSignal("login of the paused request")
	private let pausedCall: Int
	private let release = DispatchSemaphore(value: 0)
	private let state = OSAllocatedUnfairLock<(callCount: Int, wasCancelled: Bool?)>(initialState: (0, nil))

	init(pausedCall: Int) {
		self.pausedCall = pausedCall
	}

	var wasCancelled: Bool? {
		return state.withLock { $0.wasCancelled }
	}

	func resume() {
		release.signal()
	}

	func login() throws -> PCloudLogin {
		let call = state.withLock { state in
			state.callCount += 1
			return state.callCount
		}
		if call == pausedCall {
			entered.fulfill()
			if release.wait(timeout: testWaitDeadline()) == .timedOut {
				Issue.record("The paused request was never resumed")
			} else {
				let isCancelled = Task.isCancelled
				state.withLock { $0.wasCancelled = isCancelled }
			}
		}
		return try PCloudCredential.stubTokenSource.login()
	}
}

/// Forwards to a cache, and runs a hook with the element's 1-based number before saving it. By then the listing has written the element's item to the identifier cache.
private final class SaveCountingDirectoryContentCache: DirectoryContentCache {
	let cache: DirectoryContentDBCache
	private let saves = OSAllocatedUnfairLock(initialState: 0)
	private let onSave: @Sendable (_ count: Int) -> Void

	var saveCount: Int {
		return saves.withLock { $0 }
	}

	init(cache: DirectoryContentDBCache, onSave: @escaping @Sendable (_ count: Int) -> Void) {
		self.cache = cache
		self.onSave = onSave
	}

	func save(_ element: CloudItemMetadata, in snapshot: DirectoryContentSnapshot, index: Int64) throws {
		let count = saves.withLock {
			$0 += 1
			return $0
		}
		onSave(count)
		try cache.save(element, in: snapshot, index: index)
	}

	func discard(_ snapshot: DirectoryContentSnapshot) throws {
		try cache.discard(snapshot)
	}

	func publish(_ snapshot: DirectoryContentSnapshot) throws -> CloudItemList {
		return try cache.publish(snapshot)
	}

	func getPage(for folderPath: CloudPath, pageToken: String) throws -> CloudItemList {
		return try cache.getPage(for: folderPath, pageToken: pageToken)
	}
}
