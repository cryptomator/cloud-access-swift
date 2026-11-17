//
//  BoxCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptoKit
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
			let sentRequest = OSAllocatedUnfairLock<(request: URLRequest, body: Data)?>(initialState: nil)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.folderEntry(id: "3", name: "folder"), onRequest: { request in
					sentRequest.withLock { $0 = (request, URLProtocolMock.body(of: request)) }
				})
			]

			try await provider.createFolder(at: CloudPath("/folder"))

			let (request, body) = try #require(sentRequest.withLock { $0 })
			#expect(request.httpMethod == "POST")
			#expect(request.url?.absoluteString == "https://api.box.com/2.0/folders")
			#expect(try (["name": "folder", "parent": ["id": "0"]] as NSDictionary) == (JSONSerialization.jsonObject(with: body) as? NSDictionary))
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
			let sentRequest = OSAllocatedUnfairLock<(request: URLRequest, body: Data)?>(initialState: nil)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "renamed.txt"), onRequest: { request in
					sentRequest.withLock { $0 = (request, URLProtocolMock.body(of: request)) }
				})
			]

			try await provider.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/renamed.txt"))

			let (request, body) = try #require(sentRequest.withLock { $0 })
			#expect(request.httpMethod == "PUT")
			#expect(request.url?.absoluteString == "https://api.box.com/2.0/files/5")
			#expect(try (["name": "renamed.txt", "parent": ["id": "0"]] as NSDictionary) == (JSONSerialization.jsonObject(with: body) as? NSDictionary))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A mutation's request is its commit point, so it runs with its retries also if the task is cancelled during the first attempt.
		@Test
		func cancelledMutationsStillFinishTheirRequests() async throws {
			let localURL = try makeLocalFile(content: "0123456789")
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
				MutationCase(name: "commit", preparation: [URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot), URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession)] + (0 ..< 3).map { index in URLProtocolMock.handler(body: #"{"part":{"part_id":"P\#(index)"}}"#) }, success: URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]))) { provider in
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

		// MARK: - Downloads

		@Test
		func downloadWaitsWhileFileIsNotReady() async throws {
			let localURL = tmpDirURL.appendingPathComponent("download.txt")
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
			let localURL = tmpDirURL.appendingPathComponent("download.txt")
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

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

			let recordedFractions = fractions.withLock { $0 }
			#expect(recordedFractions.count == 1)
			#expect((recordedFractions.first ?? 0) > 0.5)
			#expect((recordedFractions.first ?? 1) < 1)
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

			_ = try await provider.downloadFile(from: CloudPath("/file.txt"), to: tmpDirURL.appendingPathComponent("download.txt"), progress: progress, onTaskCreation: nil)

			let recordedFractions = fractions.withLock { $0 }
			#expect(recordedFractions.count == 2)
			let fractionAfterFirstAttempt = try #require(recordedFractions.first)
			#expect(fractionAfterFirstAttempt > 0.5)
			#expect(try abs(fractionAfterFirstAttempt / 2 - #require(fractionAtRetry.withLock { $0 })) <= 0.01)
			#expect(try abs(fractionAfterFirstAttempt - #require(recordedFractions.last)) <= 0.01)
		}

		// MARK: - Uploads

		@Test
		func smallUploadSendsMultipartBodyAndHandsOverTaskOnce() async throws {
			let localURL = try makeLocalFile(content: "file content")
			let sentBodies = OSAllocatedUnfairLock(initialState: [(contentType: String?, body: Data)]())
			let recordBody: @Sendable (URLRequest) -> Void = { request in
				sentBodies.withLock { $0.append((request.value(forHTTPHeaderField: "Content-Type"), URLProtocolMock.body(of: request))) }
			}
			let taskCount = OSAllocatedUnfairLock(initialState: 0)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 503, onRequest: recordBody),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 12)]), onRequest: recordBody)
			]

			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				taskCount.withLock { $0 += 1 }
			})

			#expect(metadata.size == 12)
			#expect(taskCount.withLock { $0 } == 1)
			let (contentType, body) = try #require(sentBodies.withLock { $0 }.last)
			let boundary = try #require(contentType?.components(separatedBy: "boundary=").last)
			let expectedPrefix = "--\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n"
			let bodyString = try #require(String(data: body, encoding: .utf8))
			#expect(bodyString.hasPrefix(expectedPrefix), "\(bodyString)")
			#expect(bodyString.hasSuffix("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\nfile content\r\n--\(boundary)--\r\n"), "\(bodyString)")
			let attributes = try #require(bodyString.dropFirst(expectedPrefix.count).components(separatedBy: "\r\n").first)
			#expect(try (["name": "file.txt", "parent": ["id": "0"]] as NSDictionary) == (JSONSerialization.jsonObject(with: Data(attributes.utf8)) as? NSDictionary))
		}

		/// Only a missing scope is a login failure, and a full storage is a quota failure. Any other 403, e.g., for a folder shared view-only, passes through raw, because signing in again wouldn't fix it.
		@Test
		func uploadErrors() async throws {
			let localURL = try makeLocalFile(content: "file content")
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
			#expect((provider.convertStandardError(BoxError.apiError(statusCode: 401, code: nil, message: nil)) as? CloudProviderError) == .unauthorized)
		}

		@Test
		func chunkedUploadSendsPartsWithDigestsAndCommits() async throws {
			let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
			let content = "0123456789"
			let localURL = try makeLocalFile(content: content)
			let partRequests = OSAllocatedUnfairLock(initialState: [(request: URLRequest, body: Data)]())
			let recordPart: @Sendable (URLRequest) -> Void = { request in
				partRequests.withLock { $0.append((request, URLProtocolMock.body(of: request))) }
			}
			let commitRequest = OSAllocatedUnfairLock<(request: URLRequest, body: Data)?>(initialState: nil)
			let taskCount = OSAllocatedUnfairLock(initialState: 0)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.emptyRoot),
				URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession)
			] + (0 ..< 3).map { index in
				URLProtocolMock.handler(body: #"{"part":{"part_id":"P\#(index)","offset":\#(index * 4),"size":\#(min(4, 10 - index * 4)),"sha1":"H\#(index)"}}"#, onRequest: recordPart)
			} + [
				URLProtocolMock.handler(statusCode: 202, headerFields: ["Retry-After": "0"]),
				URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]), onRequest: { request in
					commitRequest.withLock { $0 = (request, URLProtocolMock.body(of: request)) }
				})
			]

			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				taskCount.withLock { $0 += 1 }
			})

			#expect(metadata.size == 10)
			#expect(taskCount.withLock { $0 } == 0)
			let parts = partRequests.withLock { $0 }
			#expect(parts.map { $0.request.value(forHTTPHeaderField: "content-range") } == ["bytes 0-3/10", "bytes 4-7/10", "bytes 8-9/10"])
			#expect(["0123", "4567", "89"].map { BoxCloudProviderTests.digest(of: $0) } == parts.map { $0.request.value(forHTTPHeaderField: "digest") })
			#expect(parts.map { String(data: $0.body, encoding: .utf8) } == ["0123", "4567", "89"])
			#expect(parts.map(\.request.httpMethod) == ["PUT", "PUT", "PUT"])
			let (request, body) = try #require(commitRequest.withLock { $0 })
			#expect(request.url?.absoluteString == "https://upload.box.com/api/2.0/files/upload_sessions/S/commit")
			#expect(BoxCloudProviderTests.digest(of: content) == request.value(forHTTPHeaderField: "digest"))
			let commitParts = try #require((JSONSerialization.jsonObject(with: body) as? [String: Any])?["parts"] as? [[String: Any]])
			#expect(commitParts.map { $0["part_id"] as? String } == ["P0", "P1", "P2"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func chunkedUploadOfExistingFileCreatesSessionForFile() async throws {
			let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
			let sessionRequest = OSAllocatedUnfairLock<(request: URLRequest, body: Data)?>(initialState: nil)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(statusCode: 201, body: BoxCloudProviderTests.uploadSession, onRequest: { request in
					sessionRequest.withLock { $0 = (request, URLProtocolMock.body(of: request)) }
				})
			] + (0 ..< 3).map { index in
				URLProtocolMock.handler(body: #"{"part":{"part_id":"P\#(index)"}}"#)
			} + [URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]))]

			let metadata = try await provider.uploadFile(from: makeLocalFile(content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: true, progress: nil, onTaskCreation: nil)

			#expect(metadata.size == 10)
			let (request, body) = try #require(sessionRequest.withLock { $0 })
			#expect(request.httpMethod == "POST")
			#expect(request.url?.absoluteString == "https://upload.box.com/api/2.0/files/5/upload_sessions")
			#expect(try (["file_size": 10] as NSDictionary) == (JSONSerialization.jsonObject(with: body) as? NSDictionary))
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
			] + (0 ..< 3).map { index in
				URLProtocolMock.handler(body: #"{"part":{"part_id":"P\#(index)"}}"#)
			} + [URLProtocolMock.handler(statusCode: 201, body: BoxMockResponse.files([BoxMockResponse.fileEntry(id: "5", name: "file.txt", size: 10)]))]

			_ = try await provider.uploadFile(from: makeLocalFile(content: "0123456789"), to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)

			let recordedFractions = fractions.withLock { $0 }
			#expect(recordedFractions.count == 3)
			for (index, (fraction, (bytesBefore, partLength))) in zip(recordedFractions, [(0.0, 4.0), (4.0, 4.0), (8.0, 2.0)]).enumerated() {
				#expect(fraction > (bytesBefore + partLength / 2) / 10, "part \(index)")
				#expect(fraction < 1, "part \(index)")
			}
		}

		@Test
		func cancellationBeforePartStopsChunkedUpload() async throws {
			let provider = try BoxCloudProvider(client: .mocked(), maxPageSize: .max, chunkedUploadThreshold: 10)
			let localURL = try makeLocalFile(content: "0123456789")
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

		// MARK: - Helpers

		private static func digest(of string: String) -> String {
			return "sha=\(Data(Insecure.SHA1.hash(data: Data(string.utf8))).base64EncodedString())"
		}

		/// The listing and the metadata request that precede the download of `/file.txt`.
		private func downloadPreparation() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return [
				URLProtocolMock.handler(body: BoxCloudProviderTests.rootWithFile),
				URLProtocolMock.handler(body: BoxMockResponse.fileEntry(id: "5", name: "file.txt"))
			]
		}

		private func makeLocalFile(content: String) throws -> URL {
			let localURL = tmpDirURL.appendingPathComponent("local.txt")
			try Data(content.utf8).write(to: localURL)
			return localURL
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
