//
//  BoxCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import CryptomatorCloudAccessTestSupport
import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class BoxCloudProviderTests {
		private static let rootWithFile = BoxMockResponse.items([BoxMockResponse.fileEntry(id: "5", name: "file.txt")])
		private static let rootWithFolder = BoxMockResponse.items([BoxMockResponse.folderEntry(id: "3", name: "folder")])
		private static let emptyRoot = BoxMockResponse.items([])
		private static let uploadSession = #"{"id":"S","part_size":4,"session_endpoints":{"upload_part":"https://upload.box.com/api/2.0/files/upload_sessions/S","commit":"https://upload.box.com/api/2.0/files/upload_sessions/S/commit"}}"#

		private let provider: BoxCloudProvider
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max)
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
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "file.txt")),
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder),
				URLProtocolMock.handler(body: BoxMockResponse.folderEntry(id: "3", name: "folder"))
			]

			let file = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))
			let folder = try await provider.fetchItemMetadata(at: CloudPath("/folder"))

			#expect(CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: BoxJSON.date(fromBoxDateTime: BoxMockResponse.modifiedAt), size: 7) == file)
			#expect(CloudItemMetadata(name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, lastModifiedDate: nil, size: nil) == folder)
		}

		@Test
		func pathResolutionSkipsWebLinkOfSameName() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxMockResponse.items([#"{"type":"web_link","id":"9","name":"file.txt"}"#, BoxMockResponse.fileEntry(id: "5", name: "file.txt")])),
				URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "file.txt"))
			]

			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			#expect(metadata.itemType == .file)
			#expect(metadata.size == 7)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func fetchItemListConvertsEntriesAndReturnsNextMarker() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: BoxMockResponse.items([BoxMockResponse.folderEntry(id: "3", name: "folder"), BoxMockResponse.fileEntry(id: "5", name: "file.txt")], nextMarker: "MARKER"))]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			#expect([
				CloudItemMetadata(name: "folder", cloudPath: CloudPath("/folder"), itemType: .folder, lastModifiedDate: nil, size: nil),
				CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: BoxJSON.date(fromBoxDateTime: BoxMockResponse.modifiedAt), size: 7)
			] == itemList.items)
			#expect(itemList.nextPageToken == "MARKER")
		}

		@Test
		func listingSkipsNamesThatAreNoSinglePathComponent() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: BoxMockResponse.items([
				BoxMockResponse.fileEntry(id: "4", name: "a/b"),
				#"{"type":"file","id":"6","size":7}"#,
				BoxMockResponse.fileEntry(id: "5", name: "file.txt")
			]))]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			#expect([CloudItemMetadata(name: "file.txt", cloudPath: CloudPath("/file.txt"), itemType: .file, lastModifiedDate: BoxJSON.date(fromBoxDateTime: BoxMockResponse.modifiedAt), size: 7)] == itemList.items)
		}

		@Test
		func fetchItemListErrors() async throws {
			let cases = [
				ErrorCase(name: "invalid marker", response: URLProtocolMock.handler(statusCode: 400), expectedError: CloudProviderError.pageTokenInvalid),
				ErrorCase(name: "web link", response: URLProtocolMock.handler(body: BoxMockResponse.items([#"{"type":"web_link","id":"9","name":"Link"}"#])), expectedError: BoxError.unexpectedContent),
				ErrorCase(name: "unparseable date", response: URLProtocolMock.handler(body: BoxMockResponse.items([BoxMockResponse.fileEntry(id: "5", name: "file.txt", modifiedAt: "not-a-date")])), expectedError: BoxError.unexpectedContent)
			]
			for testCase in cases {
				URLProtocolMock.requestHandler = [testCase.response]

				let error = try await #require(throws: (any Error).self, "\(testCase.name)") { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: "MARKER") }
				#expect(String(describing: testCase.expectedError) == String(describing: error), "\(testCase.name)")
			}
		}

		/// A 400 on the first page is a bad request, which a restart of the listing wouldn't heal.
		@Test
		func firstPageBadRequestIsNotPageTokenInvalid() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400)]

			await #expect(throws: BoxError.apiError(statusCode: 400, code: nil, message: nil)) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
		}

		// MARK: - Mutations

		@Test
		func createFolderPostsNameAndParent() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.folderEntry(id: "3", name: "folder"), onRequest: requests.record)
			]

			try await provider.createFolder(at: CloudPath("/folder"))

			let request = try #require(requests.requests.first)
			#expect(request.httpMethod == "POST")
			#expect(request.url?.absoluteString == "https://api.box.com/2.0/folders")
			#expect(try (["name": "folder", "parent": ["id": "0"]] as NSDictionary) == (JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? NSDictionary))
		}

		@Test
		func deleteMissingFileThrowsItemNotFound() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(statusCode: 404, body: BoxMockResponse.error(status: 404, code: "not_found"))
			]

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.deleteFile(at: CloudPath("/file.txt")) }
		}

		@Test
		func moveFilePutsNameAndParent() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "renamed.txt"), onRequest: requests.record)
			]

			try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))

			let request = try #require(requests.requests.first)
			#expect(request.httpMethod == "PUT")
			#expect(request.url?.absoluteString == "https://api.box.com/2.0/files/5")
			#expect(try (["name": "renamed.txt", "parent": ["id": "0"]] as NSDictionary) == (JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? NSDictionary))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A mutation's request is its commit point, so it runs with its retries also if the task is cancelled during the first attempt.
		@Test
		func cancelledMutationsStillFinishTheirRequests() async throws {
			let localURL = try makeLocalFile(in: tmpDirURL, named: "local.txt", content: "0123456789")
			let cases = [
				MutationCase(name: "create folder", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot)], success: URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.folderEntry(id: "3", name: "folder"))) { provider in
					try await provider.createFolder(at: CloudPath("/folder"))
				},
				MutationCase(name: "delete file", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile)], success: URLProtocolMock.handler(statusCode: 204)) { provider in
					try await provider.deleteFile(at: CloudPath("/file.txt"))
				},
				MutationCase(name: "delete folder", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder)], success: URLProtocolMock.handler(statusCode: 204)) { provider in
					try await provider.deleteFolder(at: CloudPath("/folder"))
				},
				MutationCase(name: "move file", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile), URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile)], success: URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "renamed.txt"))) { provider in
					try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))
				},
				MutationCase(name: "move folder", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder), URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder)], success: URLProtocolMock.handler(body: BoxMockResponse.folderEntry(id: "3", name: "renamed"))) { provider in
					try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/renamed"))
				},
				MutationCase(name: "commit", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot), URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession)] + BoxCloudProviderTests.uploadedPartResponses(), success: URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]))) { provider in
					_ = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
				}
			]
			for mutationCase in cases {
				let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
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

		@Test
		func mutationGuardsSendNoRequestBeyondResolution() async throws {
			let cases = try MutationGuardCases.make(localURL: makeLocalFile(in: tmpDirURL, named: "local.txt"), file: URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile), folder: URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder), missing: URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot))

			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { try BoxCloudProvider(client: .mocked(), maxPageSize: .max) }
		}

		@Test
		func unresolvablePathsThrowWithoutRequest() async throws {
			let cases = try MutationGuardCases.makeInvalidPathCases(localURL: makeLocalFile(in: tmpDirURL, named: "local.txt"), downloadURL: tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory), paths: MutationGuardCases.unresolvablePaths())
			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { try BoxCloudProvider(client: .mocked(), maxPageSize: .max) }
		}

		/// A listing of the target's folder that answers 404 shows that the folder is gone.
		@Test
		func targetLookupInMissingFolderThrowsParentFolderDoesNotExist() async throws {
			let localURL = try makeLocalFile(in: tmpDirURL, named: "local.txt")
			let operations: [(name: String, run: @Sendable (BoxCloudProvider) async throws -> Void)] = [
				("upload", { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/folder/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil) }),
				("createFolder", { try await $0.createFolder(at: CloudPath("/folder/sub")) })
			]
			for (name, run) in operations {
				let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max)
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder),
					URLProtocolMock.handler(statusCode: 404, body: BoxMockResponse.error(status: 404, code: "not_found"))
				]

				await #expect(throws: CloudProviderError.parentFolderDoesNotExist, "\(name)") { try await run(provider) }
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(name)")
			}
		}

		// MARK: - Replacing Uploads

		/// A replacing upload of a cached file confirms the file with one request by its identifier instead of listing the folder.
		@Test
		func replacingUploadConfirmsCachedFileWithoutListing() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = downloadPreparation() + [
				URLProtocolMock.handler(body: BoxCloudProviderTests.confirmation(name: "file.txt", parentID: "0", status: "active"), onRequest: requests.record),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 12)]), onRequest: requests.record)
			]
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			_ = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, named: "local.txt", content: "file content"), to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil)

			let sent = requests.requests
			try #require(sent.count == 2)
			#expect([sent[0].httpMethod, sent[0].url?.path] == ["GET", "/2.0/files/5"])
			#expect(try URLProtocolMock.queryParameter("fields", of: sent[0]) == "type,id,name,parent,item_status")
			#expect([sent[1].httpMethod, sent[1].url?.absoluteString] == ["POST", "https://upload.box.com/api/2.0/files/5/content"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Box renames a file to a name sent with its new version, which would undo a move that landed after the file was resolved.
		@Test
		func replacingUploadSendsNoName() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = downloadPreparation() + [
				URLProtocolMock.handler(body: BoxCloudProviderTests.confirmation(name: "file.txt", parentID: "0", status: "active")),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 12)]), onRequest: requests.record)
			]
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			_ = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, named: "local.txt", content: "file content"), to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil)

			let bodyString = try #require(requests.requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) })
			#expect(bodyString.contains("name=\"attributes\"\r\n\r\n{}\r\n"), "\(bodyString)")
		}

		/// Another client can rename or move the file while its new version is uploaded, and Box then reports that client's name or folder. The upload still reports the requested path, and the next access to it looks it up, so that a delete can't reach the file elsewhere.
		@Test(arguments: [("file.txt", "0"), ("renamed.txt", "0"), ("file.txt", "9"), ("file.txt", nil)] as [(String, String?)])
		func replacingUploadOfFileThatLeftLeavesPathUncached(name: String, parentID: String?) async throws {
			let hasLeft = name != "file.txt" || parentID != "0"
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = downloadPreparation() + [
				URLProtocolMock.handler(body: BoxCloudProviderTests.confirmation(name: "file.txt", parentID: "0", status: "active")),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: name, size: 12, parentID: parentID)])),
				hasLeft ? URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot, onRequest: requests.record) : URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			let metadata = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, named: "local.txt", content: "file content"), to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil)
			if hasLeft {
				await #expect(throws: CloudProviderError.itemNotFound) { try await provider.deleteFile(at: CloudPath("/file.txt")) }
			} else {
				try await provider.deleteFile(at: CloudPath("/file.txt"))
			}

			#expect(metadata.name == "file.txt")
			#expect(requests.requests.map(\.url?.path) == [hasLeft ? "/2.0/folders/0/items" : "/2.0/files/5"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A cached file that Box reports elsewhere, renamed, trashed or gone is looked up in the folder, which decides between a new version and a new file. The uploaded file then takes the path's row, so that a delete reaches it.
		@Test
		func unconfirmedCachedFileIsLookedUpInFolder() async throws {
			let cases: [(name: String, confirmation: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?))] = [
				("other parent", URLProtocolMock.handler(body: BoxCloudProviderTests.confirmation(name: "file.txt", parentID: "9", status: "active"))),
				("other name", URLProtocolMock.handler(body: BoxCloudProviderTests.confirmation(name: "renamed.txt", parentID: "0", status: "active"))),
				("trashed", URLProtocolMock.handler(body: BoxCloudProviderTests.confirmation(name: "file.txt", parentID: "0", status: "trashed"))),
				("gone", URLProtocolMock.handler(statusCode: 404, body: BoxMockResponse.error(status: 404, code: "not_found")))
			]
			let localURL = try makeLocalFile(in: tmpDirURL, named: "local.txt", content: "file content")
			for (name, confirmation) in cases {
				for (listing, expectedUploadURL) in [(BoxMockResponse.items([BoxMockResponse.fileEntry(id: "6", name: "file.txt")]), "https://upload.box.com/api/2.0/files/6/content"), (BoxCloudProviderTests.emptyRoot, "https://upload.box.com/api/2.0/files/content")] {
					let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max)
					let requests = RequestRecorder()
					URLProtocolMock.requestHandler = downloadPreparation() + [
						confirmation,
						URLProtocolMock.handler(body: listing),
						URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "6", name: "file.txt", size: 12)]), onRequest: requests.record),
						URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
					]
					_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

					_ = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil)
					try await provider.deleteFile(at: CloudPath("/file.txt"))

					#expect(requests.requests.map(\.url?.absoluteString) == [expectedUploadURL, "https://api.box.com/2.0/files/6"], "\(name)")
					#expect(URLProtocolMock.requestHandler.isEmpty, "\(name)")
				}
			}
		}

		@Test
		func cancellationDuringConfirmationStopsUploadBeforeListing() async throws {
			let provider = provider
			let localURL = try makeLocalFile(in: tmpDirURL, named: "local.txt", content: "file content")
			let canceller = TaskCanceller<CloudItemMetadata>()
			URLProtocolMock.requestHandler = downloadPreparation() + [
				URLProtocolMock.handler(body: BoxCloudProviderTests.confirmation(name: "file.txt", parentID: "9", status: "active"), onRequest: { _ in
					canceller.cancel()
				}),
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile)
			]
			_ = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			let task = canceller.start {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil)
			}

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: task) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func uploadedFileIsDeletedWithoutLookup() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "8", name: "file.txt", size: 12)])),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]

			_ = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, named: "local.txt", content: "file content"), to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
			try await provider.deleteFile(at: CloudPath("/file.txt"))

			#expect(requests.requests.map { [$0.httpMethod, $0.url?.path] } == [["DELETE", "/2.0/files/8"]])
		}

		/// The folder that the upload wrote into is replaced at its path before the upload finishes, so the uploaded file isn't cached below the replacement.
		@Test
		func uploadIntoReplacedFolderCachesNothing() async throws {
			let provider = provider
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFolder),
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 204),
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.folderEntry(id: "4", name: "folder")),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "8", name: "file.txt", size: 12)])),
				URLProtocolMock.handler(body: BoxMockResponse.items([BoxMockResponse.fileEntry(id: "9", name: "file.txt")]), onRequest: requests.record),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]

			_ = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, named: "local.txt", content: "file content"), to: CloudPath("/folder/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				try? await provider.deleteFolder(at: CloudPath("/folder"))
				try? await provider.createFolder(at: CloudPath("/folder"))
			})
			try await provider.deleteFile(at: CloudPath("/folder/file.txt"))

			#expect(requests.requests.map { [$0.httpMethod, $0.url?.path] } == [["GET", "/2.0/folders/4/items"], ["DELETE", "/2.0/files/9"]])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Downloads

		@Test
		func downloadWaitsWhileFileIsNotReady() async throws {
			let localURL = tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory)
			let taskCount = OSAllocatedUnfairLock(initialState: 0)
			URLProtocolMock.requestHandler = downloadPreparation() + [
				URLProtocolMock.handler(statusCode: 202, body: "PENDING", headerFields: ["Retry-After": "0"]),
				URLProtocolMock.handler(body: "content")
			]

			let metadata = try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: { _ in
				taskCount.withLock { $0 += 1 }
			})

			#expect(try Data("content".utf8) == Data(contentsOf: localURL))
			#expect(metadata.size == 7)
			#expect(taskCount.withLock { $0 } == 1)
		}

		@Test
		func downloadThatStaysNotReadyThrowsAndLeavesNoFile() async throws {
			let localURL = tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory)
			URLProtocolMock.requestHandler = downloadPreparation() + Array(repeating: URLProtocolMock.handler(statusCode: 202, body: "PENDING", headerFields: ["Retry-After": "0"]), count: 5)

			await #expect(throws: BoxError.fileNotReady) { try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil) }
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadReportsBytesOfTask() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try BoxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max)
			URLProtocolMock.requestHandler = downloadPreparation() + [URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"])]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory), progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 })
		}

		/// Each attempt adds the progress of its task, so a retry takes half of the transfer's share instead of pushing it past complete.
		@Test
		func retriedDownloadSharesProgressWithFirstAttempt() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let fractionAtRetry = OSAllocatedUnfairLock<Double?>(initialState: nil)
			let provider = try BoxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max)
			URLProtocolMock.requestHandler = downloadPreparation() + [
				URLProtocolMock.handler(statusCode: 202, body: "PENDING", headerFields: ["Retry-After": "0", "Content-Length": "7"]),
				URLProtocolMock.handler(body: "content", headerFields: ["Content-Length": "7"], onRequest: { _ in
					fractionAtRetry.withLock { $0 = progress.fractionCompleted }
				})
			]

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory), progress: progress, onTaskCreation: nil)

			try assertRetryHalvesProgress(fractions.withLock { $0 }, fractionAtRetry: fractionAtRetry.withLock { $0 })
		}

		// MARK: - Uploads

		@Test
		func smallUploadSendsMultipartBodyAndHandsOverTaskOnce() async throws {
			let localURL = try makeLocalFile(in: tmpDirURL, named: "local.txt", content: "file content")
			let requests = RequestRecorder()
			let taskCount = OSAllocatedUnfairLock(initialState: 0)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 503, onRequest: requests.record),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 12)]), onRequest: requests.record)
			]

			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				taskCount.withLock { $0 += 1 }
			})

			#expect(metadata.size == 12)
			#expect(taskCount.withLock { $0 } == 1)
			let request = try #require(requests.requests.last)
			let boundary = try #require(request.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: "boundary=").last)
			let expectedPrefix = "--\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n"
			let bodyString = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
			#expect(bodyString.hasPrefix(expectedPrefix), "\(bodyString)")
			#expect(bodyString.hasSuffix("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\nfile content\r\n--\(boundary)--\r\n"), "\(bodyString)")
			let attributes = try #require(bodyString.dropFirst(expectedPrefix.count).components(separatedBy: "\r\n").first)
			#expect(try (["name": "file.txt", "parent": ["id": "0"]] as NSDictionary) == (JSONSerialization.jsonObject(with: Data(attributes.utf8)) as? NSDictionary))
		}

		/// Only a missing scope is a login failure, and a full storage is a quota failure. Any other 403, e.g., for a folder shared view-only, passes through raw, because signing in again wouldn't fix it.
		@Test
		func uploadErrors() async throws {
			let localURL = try makeLocalFile(in: tmpDirURL, named: "local.txt", content: "file content")
			let cases = [
				ErrorCase(name: "storage_limit_exceeded", response: URLProtocolMock.handler(statusCode: 403, body: BoxMockResponse.error(status: 403, code: "storage_limit_exceeded")), expectedError: CloudProviderError.quotaInsufficient),
				ErrorCase(name: "insufficient_scope", response: URLProtocolMock.handler(statusCode: 403, body: BoxMockResponse.error(status: 403, code: "insufficient_scope")), expectedError: CloudProviderError.unauthorized),
				ErrorCase(name: "insufficient_scope challenge without body", response: URLProtocolMock.handler(statusCode: 403, headerFields: ["WWW-Authenticate": #"Bearer realm="Service", error="insufficient_scope", error_description="The request requires higher privileges than provided by the access token.""#]), expectedError: CloudProviderError.unauthorized),
				ErrorCase(name: "body code before challenge", response: URLProtocolMock.handler(statusCode: 403, body: BoxMockResponse.error(status: 403, code: "storage_limit_exceeded"), headerFields: ["WWW-Authenticate": #"Bearer realm="Service", error="insufficient_scope""#]), expectedError: CloudProviderError.quotaInsufficient),
				ErrorCase(name: "access_denied_insufficient_permissions", response: URLProtocolMock.handler(statusCode: 403, body: BoxMockResponse.error(status: 403, code: "access_denied_insufficient_permissions")), expectedError: BoxError.apiError(statusCode: 403, code: "access_denied_insufficient_permissions", message: nil)),
				ErrorCase(name: "no body", response: URLProtocolMock.handler(statusCode: 403), expectedError: BoxError.apiError(statusCode: 403, code: nil, message: nil))
			]
			for testCase in cases {
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
					testCase.response
				]

				let error = try await #require(throws: (any Error).self, "\(testCase.name)") { try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
				#expect(String(describing: testCase.expectedError) == String(describing: error), "\(testCase.name)")
			}
		}

		@Test
		func unauthorizedIsUnauthorized() {
			#expect((BoxCloudProvider.convertStandardError(BoxError.apiError(statusCode: 401, code: nil, message: nil)) as? CloudProviderError) == .unauthorized)
		}

		@Test
		func chunkedUploadSendsPartsWithDigestsAndCommits() async throws {
			let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
			let content = "0123456789"
			let localURL = try makeLocalFile(in: tmpDirURL, named: "local.txt", content: content)
			let requests = RequestRecorder()
			let taskCount = OSAllocatedUnfairLock(initialState: 0)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession)
			] + (0 ..< 3).map { index in
				URLProtocolMock.handler(body: #"{"part":{"part_id":"P\#(index)","offset":\#(index * 4),"size":\#(min(4, 10 - index * 4)),"sha1":"H\#(index)"}}"#, onRequest: requests.record)
			} + [
				URLProtocolMock.handler(statusCode: 202, headerFields: ["Retry-After": "0"]),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]), onRequest: requests.record)
			]

			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				taskCount.withLock { $0 += 1 }
			})

			#expect(metadata.size == 10)
			#expect(taskCount.withLock { $0 } == 0)
			let sent = requests.requests
			try #require(sent.count == 4)
			let parts = sent.prefix(3)
			#expect(parts.map { $0.value(forHTTPHeaderField: "content-range") } == ["bytes 0-3/10", "bytes 4-7/10", "bytes 8-9/10"])
			#expect(["0123", "4567", "89"].map { BoxCloudProviderTests.digest(of: $0) } == parts.map { $0.value(forHTTPHeaderField: "digest") })
			#expect(parts.map { $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } } == ["0123", "4567", "89"])
			#expect(parts.map(\.httpMethod) == ["PUT", "PUT", "PUT"])
			let commit = try #require(sent.last)
			#expect(commit.url?.absoluteString == "https://upload.box.com/api/2.0/files/upload_sessions/S/commit")
			#expect(BoxCloudProviderTests.digest(of: content) == commit.value(forHTTPHeaderField: "digest"))
			let commitParts = try #require((JSONSerialization.jsonObject(with: commit.httpBody ?? Data()) as? [String: Any])?["parts"] as? [[String: Any]])
			#expect(commitParts.map { $0["part_id"] as? String } == ["P0", "P1", "P2"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func chunkedUploadOfExistingFileCreatesSessionForFile() async throws {
			let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession, onRequest: requests.record)
			] + BoxCloudProviderTests.uploadedPartResponses() + [URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]))]

			let metadata = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, named: "local.txt", content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil)

			#expect(metadata.size == 10)
			let request = try #require(requests.requests.first)
			#expect(request.httpMethod == "POST")
			#expect(request.url?.absoluteString == "https://upload.box.com/api/2.0/files/5/upload_sessions")
			#expect(try (["file_size": 10] as NSDictionary) == (JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? NSDictionary))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Only the lookup of the existing file decides whether the upload creates a new file, so a 404 later in the upload of a new version is thrown without requesting a new-file upload.
		@Test
		func notFoundDuringUploadOfExistingFileDoesNotCreateNewFile() async throws {
			let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession)
			] + BoxCloudProviderTests.uploadedPartResponses() + [
				URLProtocolMock.handler(statusCode: 404, body: BoxMockResponse.error(status: 404, code: "not_found")),
				URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession)
			]

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, named: "local.txt", content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		/// A symbolic link's own size is the length of its destination, 9 bytes for `local.txt`, so only the target's 10 bytes reach the threshold.
		@Test
		func chunkedUploadThroughSymbolicLinkUsesSizeOfTarget() async throws {
			let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
			let localURL = try makeLocalFile(in: tmpDirURL, named: "local.txt", content: "0123456789")
			let linkURL = tmpDirURL.appending(component: "link.txt", directoryHint: .notDirectory)
			try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: localURL.lastPathComponent)
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession, onRequest: requests.record)
			] + BoxCloudProviderTests.uploadedPartResponses() + [URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]))]

			_ = try await provider.uploadFile(from: linkURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)

			let request = try #require(requests.requests.first)
			#expect(try (JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["file_size"] as? Int == 10)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func chunkedUploadReportsBytesOfParts() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try BoxCloudProvider(client: .mocked(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions)), maxPageSize: .max, chunkedUploadThreshold: 10)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession)
			] + BoxCloudProviderTests.uploadedPartResponses() + [URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]))]

			_ = try await provider.uploadFile(from: makeLocalFile(in: tmpDirURL, named: "local.txt", content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

			assertTransferProgress(fractions.withLock { $0 }, parts: [(4, 10), (4, 10), (2, 10)])
		}

		@Test
		func cancellationBeforePartStopsChunkedUpload() async throws {
			let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
			let localURL = try makeLocalFile(in: tmpDirURL, named: "local.txt", content: "0123456789")
			let canceller = TaskCanceller<CloudItemMetadata>()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession),
				URLProtocolMock.handler(body: #"{"part":{"part_id":"P0"}}"#, onRequest: { _ in
					canceller.cancel()
				}),
				URLProtocolMock.handler(body: #"{"part":{"part_id":"P1"}}"#)
			]

			let task = canceller.start {
				return try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
			}

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: task) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		// MARK: - Late Responses

		/// A lookup that returns after a rename and a new item at the name would cache the renamed item at the name, so its result is refused and the path resolves to the new item's row.
		@Test
		func lateLookupAfterRenameAndNewItemResolvesToNewItem() async throws {
			let tokenSource = HookedTokenSource()
			let provider = try BoxCloudProvider(client: .mocked(tokenSource: tokenSource), maxPageSize: .max)
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "renamed.txt")),
				URLProtocolMock.handler(body: BoxMockResponse.items([BoxMockResponse.fileEntry(id: "5", name: "renamed.txt")])),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.folderEntry(id: "8", name: "file.txt")),
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxMockResponse.folderEntry(id: "8", name: "file.txt"), onRequest: requests.record)
			]
			tokenSource.setHook(atCall: 1) {
				try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))
				try await provider.createFolder(at: CloudPath("/file.txt"))
			}

			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/file.txt"))

			#expect(metadata.itemType == .folder)
			#expect(requests.requests.map(\.url?.path) == ["/2.0/folders/8"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test(arguments: LateMutationKind.allCases)
		func lateMutationResponseLeavesMovedAwayTargetUncached(kind: LateMutationKind) async throws {
			let tokenSource = HookedTokenSource()
			let provider = try BoxCloudProvider(client: .mocked(tokenSource: tokenSource), maxPageSize: .max)
			let testCase = try lateMutationCase(kind)
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = testCase.responses + [URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot, onRequest: requests.record)]
			tokenSource.setHook(atCall: testCase.preparation.count + 1) {
				try await testCase.rename(on: provider)
			}

			try await testCase.perform(on: provider)

			await testCase.expectTargetIsLookedUp(on: provider, requests: requests, lookupPath: "/2.0/folders/0/items")
		}

		/// Box may have applied the move, so the item's rows go although the response is unusable, and a lookup that began before the move can't cache the item that the target held.
		@Test(arguments: ["{", #"{"type":"web_link","id":"5","name":"b"}"#], [false, true])
		func moveWithUnusableResponseEvictsItemAndRefusesOlderLookup(body: String, isFolder: Bool) async throws {
			let tokenSource = HookedTokenSource()
			let provider = try BoxCloudProvider(client: .mocked(tokenSource: tokenSource), maxPageSize: .max)
			let requests = RequestRecorder()
			let entry: (String, String) -> String = { id, name in
				isFolder ? BoxMockResponse.folderEntry(id: id, name: name) : BoxMockResponse.fileEntry(id: id, name: name)
			}
			let root = BoxMockResponse.items([entry("5", "a"), entry("5", "alias")])
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: root),
				URLProtocolMock.handler(body: entry("5", "a")),
				URLProtocolMock.handler(body: root),
				URLProtocolMock.handler(body: entry("5", "alias")),
				URLProtocolMock.handler(body: root),
				URLProtocolMock.handler(body: body),
				URLProtocolMock.handler(body: BoxMockResponse.items([entry("9", "b")])),
				URLProtocolMock.handler(body: BoxMockResponse.items([entry("5", "b")])),
				URLProtocolMock.handler(body: entry("5", "b"), onRequest: requests.record),
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot, onRequest: requests.record)
			]
			_ = try await provider.fetchItemMetadata(at: CloudPath("/a"))
			_ = try await provider.fetchItemMetadata(at: CloudPath("/alias"))
			tokenSource.setHook(atCall: 5) {
				await #expect(throws: BoxError.unexpectedContent) {
					if isFolder {
						try await provider.moveFolder(from: CloudPath("/a"), to: CloudPath("/b"))
					} else {
						try await provider.moveFile(from: CloudPath("/a"), to: CloudPath("/b"))
					}
				}
			}

			_ = try await provider.fetchItemMetadata(at: CloudPath("/b"))
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/alias")) }

			#expect(requests.requests.map(\.url?.path) == [isFolder ? "/2.0/folders/5" : "/2.0/files/5", "/2.0/folders/0/items"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Box may have applied a delete whose response was lost, so the next read looks the path up instead of reaching the item by its old identifier.
		@Test(arguments: [false, true])
		func deleteWithLostResponseLeavesPathUncached(isFolder: Bool) async throws {
			let cloudPath = CloudPath(isFolder ? "/folder" : "/file.txt")
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: isFolder ? BoxCloudProviderTests.rootWithFolder : BoxCloudProviderTests.rootWithFile),
				{ _ in throw URLError(.networkConnectionLost) },
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot, onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.noInternetConnection) {
				if isFolder {
					try await provider.deleteFolder(at: cloudPath)
				} else {
					try await provider.deleteFile(at: cloudPath)
				}
			}
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: cloudPath) }

			#expect(requests.requests.map(\.url?.path) == ["/2.0/folders/0/items"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Box may have applied a move whose response was lost, so the next read at the source looks the path up instead of reaching the moved item by its old identifier.
		@Test
		func moveWithLostResponseLeavesSourceUncached() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				{ _ in throw URLError(.networkConnectionLost) },
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot, onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt")) }
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/file.txt")) }

			#expect(requests.requests.map(\.url?.path) == ["/2.0/folders/0/items"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Helpers

		private func lateMutationCase(_ kind: LateMutationKind) throws -> LateMutationCase {
			let entry: (String) -> String = { name in
				kind == .createFolder ? BoxMockResponse.folderEntry(id: "8", name: name) : BoxMockResponse.fileEntry(id: "8", name: name)
			}
			let source = URLProtocolMock.handler(body: BoxMockResponse.items([entry("src")]))
			let atTarget = URLProtocolMock.handler(body: BoxMockResponse.items([entry("new")]))
			let mutationResponse: LateMutationCase.Response = switch kind {
			case .upload: URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([entry("new")]))
			case .createFolder: URLProtocolMock.handler(statusCode: 201, body: entry("new"))
			case .move: URLProtocolMock.handler(body: entry("new"))
			}
			return try LateMutationCase(kind: kind, localURL: makeLocalFile(in: tmpDirURL, named: "local.txt"), preparation: kind == .move ? [source, source] : [URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot)], renameResponses: [atTarget, atTarget, URLProtocolMock.handler(body: entry("moved"))], mutationResponses: [mutationResponse])
		}

		/// The response of a request for a file's type, identifier, name, parent and status.
		private static func confirmation(name: String, parentID: String, status: String) -> String {
			return #"{"type":"file","id":"5","etag":"1","name":"\#(name)","parent":{"type":"folder","id":"\#(parentID)","name":"Folder"},"item_status":"\#(status)"}"#
		}

		private static func digest(of string: String) -> String {
			return "sha=\(Data(Insecure.SHA1.hash(data: Data(string.utf8))).base64EncodedString())"
		}

		/// The responses to the three part uploads of a 10-byte file in `uploadSession`'s 4-byte parts.
		private static func uploadedPartResponses() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return (0 ..< 3).map { index in
				URLProtocolMock.handler(body: #"{"part":{"part_id":"P\#(index)"}}"#)
			}
		}

		/// The listing and the metadata request that precede the download of `/file.txt`.
		private func downloadPreparation() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "file.txt"))
			]
		}
	}
}

private struct ErrorCase {
	let name: String
	let response: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let expectedError: Error
}

private struct MutationCase {
	let name: String
	/// The responses to the requests before the mutation's request.
	let preparation: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)]
	/// The response to the retry of the mutation's request.
	let success: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
	let operation: @Sendable (BoxCloudProvider) async throws -> Void
}
