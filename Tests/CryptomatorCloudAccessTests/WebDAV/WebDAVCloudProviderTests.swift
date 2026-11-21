//
//  WebDAVCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 14.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

enum WebDAVProviderTestsError: Error {
	case missingTestResource
}

extension UnitTests {
	final class WebDAVCloudProviderTests {
		let tmpDirURL: URL
		let baseURL: URL
		let client: WebDAVClient
		let provider: WebDAVCloudProvider

		init() throws {
			URLProtocolMock.requestHandler = []
			URLProtocolAuthenticationMock.authenticationChallenges = []
			URLProtocolSequenceMock.steps = []
			RecordingURLProtocolMock.log.reset()
			RecordingURLProtocolAuthenticationMock.log.reset()
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			self.baseURL = try #require(URL(string: "/cloud/remote.php/webdav/"))
			self.client = .mocked(baseURL: baseURL)
			self.provider = try WebDAVCloudProvider(client: client)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func testFetchItemMetadata() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt"))
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(metadata.name == "About.txt")
			#expect(metadata.cloudPath.path == "/Documents/About.txt")
			#expect(metadata.itemType == .file)
			#expect(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT") == metadata.lastModifiedDate)
			#expect(metadata.size == 1074)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The response lists the parent folder before the requested file.
		@Test
		func fetchItemMetadataTakesElementOfRequestedItem() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let propfindData = Data("""
			<d:multistatus xmlns:d="DAV:">
			<d:response><d:href>/cloud/remote.php/webdav/Documents/</d:href><d:propstat><d:prop><d:resourcetype><d:collection /></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
			<d:response><d:href>/cloud/remote.php/webdav/Documents/About.txt</d:href><d:propstat><d:prop><d:getcontentlength>1074</d:getcontentlength><d:resourcetype /></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
			</d:multistatus>
			""".utf8)
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt"))
			#expect(metadata.cloudPath.path == "/Documents/About.txt")
			#expect(metadata.itemType == .file)
			#expect(metadata.size == 1074)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func fetchItemMetadataWithNotFoundError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, nil)
			})

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func fetchItemMetadataWithUnauthorizedError() async throws {
			let unauthorizedProvider = try WebDAVCloudProvider(client: .mocked(baseURL: baseURL, protocolClass: RecordingURLProtocolAuthenticationMock.self))

			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let failureResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
			let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
			URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
			await #expect(throws: CloudProviderError.unauthorized) { try await unauthorizedProvider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")) }
			#expect(RecordingURLProtocolAuthenticationMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
		}

		@Test
		func fetchItemMetadataWithCancelledRequest() async throws {
			URLProtocolMock.requestHandler.append({ _ in
				throw URLError(.cancelled)
			})

			await #expect(throws: CancellationError.self) { try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")) }
		}

		@Test
		func fetchItemMetadataWithMissingResourcetype() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let propfindData = try getTestData(forResource: "item-metadata-missing-resourcetype", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt"))
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(metadata.name == "About.txt")
			#expect(metadata.cloudPath.path == "/Documents/About.txt")
			#expect(metadata.itemType == .file)
			#expect(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT") == metadata.lastModifiedDate)
			#expect(metadata.size == 1074)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func testFetchItemList() async throws {
			let baseURL: URL = baseURL
			let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == baseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 1 /cloud/remote.php/webdav/"])
			#expect(itemList.items.count == 5)
			#expect(itemList.items.contains(where: { $0.name == "Documents" }))
			#expect(itemList.items.contains(where: { $0.name == "Nextcloud Manual.pdf" }))
			#expect(itemList.items.contains(where: { $0.name == "Nextcloud intro.mp4" }))
			#expect(itemList.items.contains(where: { $0.name == "Nextcloud.png" }))
			#expect(itemList.items.contains(where: { $0.name == "Photos" }))
			#expect(itemList.nextPageToken == nil)
			#expect(URLProtocolMock.requestHandler.isEmpty)
			try assertDirectoryContentCacheIsEmpty(provider.directoryContentCache)
		}

		@Test
		func fetchItemListWithNotFoundError() async throws {
			let baseURL: URL = baseURL
			let propfindResponse = try #require(HTTPURLResponse(url: baseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == baseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, nil)
			})

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 1 /cloud/remote.php/webdav/"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func fetchItemListWithTypeMismatchError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.fetchItemList(forFolderAt: CloudPath("/Documents/About.txt"), withPageToken: nil) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 1 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func fetchItemListWithUnauthorizedError() async throws {
			let unauthorizedProvider = try WebDAVCloudProvider(client: .mocked(baseURL: baseURL, protocolClass: RecordingURLProtocolAuthenticationMock.self))

			let failureResponse = try #require(HTTPURLResponse(url: baseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
			let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
			URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
			await #expect(throws: CloudProviderError.unauthorized) { try await unauthorizedProvider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			#expect(RecordingURLProtocolAuthenticationMock.log.wireSummaries == ["PROPFIND Depth 1 /cloud/remote.php/webdav/"])
			#expect(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
		}

		@Test
		func fetchItemListInterleavedWithAnotherListingOfTheSameFolder() async throws {
			let provider = try WebDAVCloudProvider(client: client, maxPageSize: 2)
			let itemListData = try getTestData(forResource: "item-list", withExtension: "xml")
			try enqueueResponse(statusCode: 200, data: itemListData, for: baseURL)
			try enqueueResponse(statusCode: 200, data: removingResponse(withHref: "/cloud/remote.php/webdav/Documents/", from: itemListData), for: baseURL)

			let firstPage = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			let otherItemList = try await provider.fetchItemListExhaustively(forFolderAt: CloudPath("/"))
			let itemList = try await provider.fetchItemListExhaustively(forFolderAt: CloudPath("/"), appendTo: firstPage)

			#expect(WebDAVCloudProviderTests.itemListNames == itemList.items.map(\.name).sorted())
			#expect(WebDAVCloudProviderTests.itemListNames.filter { $0 != "Documents" } == otherItemList.items.map(\.name).sorted())
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func fetchItemListWhileAnotherListingOfTheSameFolderFillsTheCache() async throws {
			let provider = try WebDAVCloudProvider(client: .mocked(baseURL: baseURL, protocolClass: FirstRequestHoldingProtocolMock.self), maxPageSize: 2)
			let itemListData = try getTestData(forResource: "item-list", withExtension: "xml")
			// The held request takes its response only once it's released, after the other listing's request, so its response is queued second.
			try enqueueResponse(statusCode: 200, data: removingResponse(withHref: "/cloud/remote.php/webdav/Documents/", from: itemListData), for: baseURL)
			try enqueueResponse(statusCode: 200, data: itemListData, for: baseURL)
			let hold = RequestHold()
			FirstRequestHoldingProtocolMock.arm(hold)

			let heldListing = Task {
				try await provider.fetchItemListExhaustively(forFolderAt: CloudPath("/"))
			}
			await hold.reached.wait()
			guard hold.reached.fulfillmentCount > 0 else {
				// The timed-out wait has recorded the failure. Disarm the hold, and release it in case the first listing's request took it meanwhile.
				_ = FirstRequestHoldingProtocolMock.takePendingHold()
				hold.release()
				_ = try? await cancellingValue(of: heldListing)
				return
			}
			let otherItemList: CloudItemList
			do {
				otherItemList = try await provider.fetchItemListExhaustively(forFolderAt: CloudPath("/"))
			} catch {
				hold.release()
				_ = try? await cancellingValue(of: heldListing)
				throw error
			}
			hold.release()
			let itemList = try await cancellingValue(of: heldListing)

			#expect(WebDAVCloudProviderTests.itemListNames == itemList.items.map(\.name).sorted())
			#expect(WebDAVCloudProviderTests.itemListNames.filter { $0 != "Documents" } == otherItemList.items.map(\.name).sorted())
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func fetchItemListWithTruncatedResponseLeavesNoRows() async throws {
			let document = try #require(String(data: getTestData(forResource: "item-list", withExtension: "xml"), encoding: .utf8))
			var end = document.startIndex
			for _ in 0 ..< 3 {
				end = try #require(document.range(of: "</d:response>", range: end ..< document.endIndex)).upperBound
			}
			try enqueueResponse(statusCode: 200, data: Data(document[..<end].utf8), for: baseURL)

			let error = try await #require(throws: (any Error).self) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			#expect(XMLParser.errorDomain == (error as NSError).domain)
			try assertDirectoryContentCacheIsEmpty(provider.directoryContentCache)
		}

		/// The child before the oversized `href` is cached before the parsing aborts, so the empty cache shows that the failed fill was discarded.
		@Test
		func fetchItemListWithOversizedHrefLeavesNoRows() async throws {
			let oversizedHref = baseURL.path + "/" + String(repeating: "b", count: WebDAVXMLLimits.maxTextLength)
			try enqueueResponse(statusCode: 200, data: getMultistatusData(forHrefs: [baseURL.path + "/", baseURL.path + "/a.txt", oversizedHref]), for: baseURL)

			await #expect(throws: WebDAVProviderError.responseTooLarge) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			try assertDirectoryContentCacheIsEmpty(provider.directoryContentCache)
		}

		/// The line names the cap that aborted the parsing, so that it tells the delegate's abort from the guard's refusal of the same error.
		@Test
		func abortedListingLogsExceededCap() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let nesting = foreignNesting(count: WebDAVXMLLimits.maxDepth)
			let cases = [
				(getMultistatusData(forHrefs: [baseURL.path + "/", baseURL.path + "/" + String(repeating: "b", count: WebDAVXMLLimits.maxTextLength)]), "PropfindResponseParser: aborting, because an element's text exceeds \(WebDAVXMLLimits.maxTextLength) bytes"),
				(getMultistatusData(forContent: "<d:response xmlns:x=\"urn:example\">\(nesting)</d:response>"), "PropfindResponseParser: aborting, because the nesting exceeds \(WebDAVXMLLimits.maxDepth) levels")
			]
			for (data, expectedLine) in cases {
				try enqueueResponse(statusCode: 200, data: data, for: baseURL)
				await #expect(throws: WebDAVProviderError.responseTooLarge) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
				#expect(logCapture.messages.filter { $0.hasPrefix("PropfindResponseParser: aborting") }.last == expectedLine, "\(logCapture.joinedMessages)")
			}
		}

		/// `XMLParser` would reject the malformed tail, so `responseTooLarge` shows that the guard refused the body before it was parsed.
		@Test
		func fetchItemListWithTooManyAttributesLeavesNoRows() async throws {
			try enqueueResponse(statusCode: 200, data: listingWithTooManyAttributes(value: "v"), for: baseURL)

			await #expect(throws: WebDAVProviderError.responseTooLarge) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			try assertDirectoryContentCacheIsEmpty(provider.directoryContentCache)
		}

		@Test
		func fetchItemListWithDoctypeLeavesNoRows() async throws {
			let data = try Data("<!DOCTYPE d:multistatus>".utf8) + getTestData(forResource: "item-list", withExtension: "xml").drop(while: { $0 != UInt8(ascii: "\n") })
			try enqueueResponse(statusCode: 200, data: data, for: baseURL)

			await #expect(throws: WebDAVProviderError.invalidResponse) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			try assertDirectoryContentCacheIsEmpty(provider.directoryContentCache)
		}

		/// libxml2 parses this listing, but `WebDAVXMLGuard` refuses UTF-16.
		@Test
		func fetchItemListOfUTF16ResponseLeavesNoRows() async throws {
			let document = try #require(String(data: getTestData(forResource: "item-list", withExtension: "xml"), encoding: .utf8))
			let data = utf16Data(document, bigEndian: false, withByteOrderMark: true)
			try enqueueResponse(statusCode: 200, data: data, for: baseURL)

			await #expect(throws: WebDAVProviderError.invalidResponse) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			try assertDirectoryContentCacheIsEmpty(provider.directoryContentCache)
		}

		@Test
		func refusedListingLogsConstructWithoutContent() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			try enqueueResponse(statusCode: 200, data: listingWithTooManyAttributes(value: "SECRET-MARKER"), for: baseURL)

			await #expect(throws: WebDAVProviderError.responseTooLarge) { try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
			expectAttributeRefusalLog(in: logCapture, prefix: "WebDAVCloudProvider: refused response markup:", marker: "SECRET-MARKER")
		}

		/// The body is under the 1 MiB cap of the transport, which would refuse it first otherwise.
		@Test
		func fetchItemMetadataWithOversizedCommentThrowsResponseTooLarge() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let comment = "<!--" + String(repeating: "c", count: WebDAVXMLLimits.maxDelimitedLength + 1) + "-->"
			let data = Data(comment.utf8) + getMultistatusData(forHrefs: [responseURL.path])
			try enqueueResponse(statusCode: 200, data: data, for: responseURL)

			await #expect(throws: WebDAVProviderError.responseTooLarge) { try await provider.fetchItemMetadata(at: CloudPath("/Documents/About.txt")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func testDownloadFile() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let progress = Progress(totalUnitCount: 1)

			let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path, request.httpMethod == "PROPFIND" else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			let getData = try getTestData(forResource: "item-data", withExtension: "txt")
			let getResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path, request.httpMethod == "GET" else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (getResponse, getData)
			})

			let metadata = try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, progress: progress, onTaskCreation: nil)
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt", "GET /cloud/remote.php/webdav/Documents/About.txt"])
			let expectedData = try getTestData(forResource: "item-data", withExtension: "txt")
			let actualData = try Data(contentsOf: localURL)
			#expect(expectedData == actualData)
			#expect(metadata.name == "About.txt")
			#expect(metadata.cloudPath.path == "/Documents/About.txt")
			#expect(metadata.itemType == .file)
			#expect(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT") == metadata.lastModifiedDate)
			#expect(expectedData.count == metadata.size)
			#expect(progress.fractionCompleted == 1)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider: WebDAVCloudProvider = provider
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let getData = try getTestData(forResource: "item-data", withExtension: "txt")
			let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
			let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
			try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)
			try enqueueResponse(statusCode: 200, data: getData, for: responseURL, onRequest: {
				#expect(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
			})

			let download = Task {
				try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, progress: nil, onTaskCreation: { task in
					taskStates.withLock { $0.append(task.state) }
					try? await Task.sleep(for: .milliseconds(100))
					onTaskCreationReturned.withLock { $0 = true }
				})
			}
			_ = try await cancellingValue(of: download)

			#expect(taskStates.withLock { $0 } == [.suspended])
			#expect(try getData == Data(contentsOf: localURL))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider: WebDAVCloudProvider = provider
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
			let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
			let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
			try enqueueResponse(statusCode: 404, for: responseURL)
			try enqueueResponse(statusCode: 201, data: Data(), for: responseURL, onRequest: {
				#expect(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
			})
			try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)

			let upload = Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: nil, onTaskCreation: { task in
					taskStates.withLock { $0.append(task.state) }
					try? await Task.sleep(for: .milliseconds(100))
					onTaskCreationReturned.withLock { $0 = true }
				})
			}
			_ = try await cancellingValue(of: upload)

			#expect(taskStates.withLock { $0 } == [.suspended])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadFileWithCancellationDuringOnTaskCreation() async throws {
			let provider: WebDAVCloudProvider = provider
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)
			try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-data", withExtension: "txt"), for: responseURL)

			let download = Task {
				try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, progress: nil, onTaskCreation: { _ in
					withUnsafeCurrentTask { $0?.cancel() }
				})
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }

			#expect(URLProtocolMock.requestHandler.count == 1, "The task of a cancelled download must not be resumed")
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func uploadFileWithCancellationDuringOnTaskCreation() async throws {
			let provider: WebDAVCloudProvider = provider
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
			try enqueueResponse(statusCode: 404, for: responseURL)
			try enqueueResponse(statusCode: 201, data: Data(), for: responseURL)

			let upload = Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
					withUnsafeCurrentTask { $0?.cancel() }
				})
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }

			#expect(URLProtocolMock.requestHandler.count == 1, "The task of a cancelled upload must not be resumed")
		}

		/// A task that is cancelled before the session resumed it terminates without the session having registered it, so the session has to complete the call itself.
		@Test
		func downloadFileDoesNotHangWhenOnTaskCreationCancelsTask() async throws {
			let provider: WebDAVCloudProvider = provider
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)

			let download = Task {
				try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, progress: nil, onTaskCreation: { task in
					task.cancel()
				})
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }

			#expect(URLProtocolMock.requestHandler.isEmpty)
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		/// See the rationale on the download variant.
		@Test
		func uploadFileDoesNotHangWhenOnTaskCreationCancelsTask() async throws {
			let provider: WebDAVCloudProvider = provider
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
			try enqueueResponse(statusCode: 404, for: responseURL)

			let upload = Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: nil, onTaskCreation: { task in
					task.cancel()
				})
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }

			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The rejected authentication challenge must not end the call: the session still uses the task until its terminal delegate call.
		@Test
		func downloadFileWithUnauthorizedTransferReturnsAfterTaskCompletion() async throws {
			let (gatedProvider, gate) = try makeGatedProvider()
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

			let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolSequenceMock.steps.append(.response(propfindResponse, propfindData))

			let failureResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolSequenceMock.steps.append(.authChallenge(URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)))

			let returned = TestSignal("downloadFile returned before the task completed")
			let download = Task {
				defer { returned.fulfill() }
				return try await gatedProvider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL)
			}
			await gate.challengeRejected.wait()
			await returned.expectNoFulfillment(within: .seconds(0.2))
			gate.completionGate.signal()
			await #expect(throws: CloudProviderError.unauthorized) { try await cancellingValue(of: download) }

			#expect(URLProtocolSequenceMock.steps.isEmpty)
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		/// See the rationale on the download variant.
		@Test
		func uploadFileWithUnauthorizedTransferReturnsAfterTaskCompletion() async throws {
			let (gatedProvider, gate) = try makeGatedProvider()
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolSequenceMock.steps.append(.response(propfindResponse, nil))

			let failureResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolSequenceMock.steps.append(.authChallenge(URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)))

			let returned = TestSignal("uploadFile returned before the task completed")
			let upload = Task {
				defer { returned.fulfill() }
				return try await gatedProvider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false)
			}
			await gate.challengeRejected.wait()
			await returned.expectNoFulfillment(within: .seconds(0.2))
			gate.completionGate.signal()
			await #expect(throws: CloudProviderError.unauthorized) { try await cancellingValue(of: upload) }

			#expect(URLProtocolSequenceMock.steps.isEmpty)
		}

		@Test
		func downloadFileWithTransportError() async throws {
			let provider: WebDAVCloudProvider = provider
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)
			URLProtocolMock.requestHandler.append({ _ in
				throw URLProtocolMockError.simulatedTransportFailure
			})

			let download = Task {
				try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL)
			}
			let error = try await #require(throws: (any Error).self) { try await cancellingValue(of: download) }
			// Transport failures must not be silently mapped to a `CloudProviderError` — that would
			// hide the actual failure from callers. The exact wrapping URLSession applies to the
			// `URLProtocol`-thrown error is opaque, so we assert the regression of interest.
			#expect((error as? CloudProviderError) == nil, "Transport failure was unexpectedly mapped: \(error)")

			#expect(URLProtocolMock.requestHandler.isEmpty)
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func uploadFileWithTransportError() async throws {
			let provider: WebDAVCloudProvider = provider
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
			try enqueueResponse(statusCode: 404, for: responseURL)
			URLProtocolMock.requestHandler.append({ _ in
				throw URLProtocolMockError.simulatedTransportFailure
			})

			let upload = Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false)
			}
			let error = try await #require(throws: (any Error).self) { try await cancellingValue(of: upload) }
			// See the download variant for why we assert "not a CloudProviderError"
			// rather than equality against `URLProtocolMockError.simulatedTransportFailure`.
			#expect((error as? CloudProviderError) == nil, "Transport failure was unexpectedly mapped: \(error)")

			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadFileWithNotFoundError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

			let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			let getResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (getResponse, nil)
			})

			let progress = Progress(totalUnitCount: 1)
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL, progress: progress, onTaskCreation: nil) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt", "GET /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
			#expect(progress.fractionCompleted < 1)
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func downloadFileWithAlreadyExistsError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)

			let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			let getData = try getTestData(forResource: "item-data", withExtension: "txt")
			let getResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (getResponse, getData)
			})

			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt", "GET /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadFileWithTypeMismatchError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

			let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadFileWithUnauthorizedError() async throws {
			let unauthorizedProvider = try WebDAVCloudProvider(client: .mocked(baseURL: baseURL, protocolClass: RecordingURLProtocolAuthenticationMock.self))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)

			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let failureResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
			let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
			URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
			await #expect(throws: CloudProviderError.unauthorized) { try await unauthorizedProvider.downloadFile(from: CloudPath("/Documents/About.txt"), to: localURL) }
			#expect(RecordingURLProtocolAuthenticationMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
		}

		@Test
		func testUploadFile() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, nil)
			})

			let putResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil))
			let putData = Data()
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (putResponse, putData)
			})

			let propfindResponseAfterUpload = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			let propfindDataAfterUpload = try getTestData(forResource: "item-metadata", withExtension: "xml")
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponseAfterUpload, propfindDataAfterUpload)
			})

			let progress = Progress(totalUnitCount: 1)
			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt", "PUT /cloud/remote.php/webdav/Documents/About.txt", "PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(metadata.name == "About.txt")
			#expect(metadata.cloudPath.path == "/Documents/About.txt")
			#expect(metadata.itemType == .file)
			#expect(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT") == metadata.lastModifiedDate)
			#expect(metadata.size == 1074)
			#expect(progress.fractionCompleted == 1)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The upload is committed once the `PUT` request was sent, so a cancellation after that must not hide its result.
		@Test
		func uploadFileWithCancellationDuringTransfer() async throws {
			let provider: WebDAVCloudProvider = provider
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
			let progress = Progress(totalUnitCount: 1)
			let putStarted = TestSignal("PUT request started")
			let putGate = DispatchSemaphore(value: 0)
			try enqueueResponse(statusCode: 404, for: responseURL)
			try enqueueResponse(statusCode: 201, data: Data(), for: responseURL, onRequest: {
				putStarted.fulfill()
				_ = putGate.wait(timeout: testWaitDeadline())
			})
			try enqueueResponse(statusCode: 200, data: getTestData(forResource: "item-metadata", withExtension: "xml"), for: responseURL)

			let upload = Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil)
			}
			await putStarted.wait()
			#expect(progress.fractionCompleted < 1)
			upload.cancel()
			putGate.signal()
			let metadata = try await cancellingValue(of: upload)

			#expect(metadata.name == "About.txt")
			#expect(metadata.cloudPath.path == "/Documents/About.txt")
			#expect(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT") == metadata.lastModifiedDate)
			#expect(progress.fractionCompleted == 1)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileWithQuotaInsufficientError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)
			let progress = Progress(totalUnitCount: 1)
			try enqueueResponse(statusCode: 404, for: responseURL)
			try enqueueResponse(statusCode: 507, for: responseURL)

			await #expect(throws: CloudProviderError.quotaInsufficient) { try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false, progress: progress, onTaskCreation: nil) }
			#expect(progress.fractionCompleted < 1)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileWithReplaceExisting() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

			let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			let putData = Data()
			let putResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (putResponse, putData)
			})

			let propfindResponseAfterUpload = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			let propfindDataAfterUpload = try getTestData(forResource: "item-metadata", withExtension: "xml")
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponseAfterUpload, propfindDataAfterUpload)
			})

			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true)
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt", "PUT /cloud/remote.php/webdav/Documents/About.txt", "PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(metadata.name == "About.txt")
			#expect(metadata.cloudPath.path == "/Documents/About.txt")
			#expect(metadata.itemType == .file)
			#expect(Date.date(fromRFC822: "Wed, 19 Feb 2020 10:24:12 GMT") == metadata.lastModifiedDate)
			#expect(metadata.size == 1074)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileWithNotFoundError() async {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == [])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileWithAlreadyExistsError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

			let propfindData = try getTestData(forResource: "item-metadata", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileWithTypeMismatchError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false, attributes: nil)

			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, nil)
			})

			let putError = POSIXError(.EISDIR)
			URLProtocolMock.requestHandler.append({ _ in
				throw putError
			})

			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false) }
		}

		@Test
		func uploadFileWithReplaceExistingAndAlreadyExistsError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

			let propfindData = try getTestData(forResource: "item-list", withExtension: "xml")
			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, propfindData)
			})

			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: true) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileWithParentFolderDoesNotExistError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, nil)
			})

			let putResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (putResponse, nil)
			})
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt", "PUT /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileWithParentFolderDoesNotExistErrorWhenReceiving404Error() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

			let propfindResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (propfindResponse, nil)
			})

			let putResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (putResponse, nil)
			})
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt", "PUT /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileWithUnauthorizedError() async throws {
			let unauthorizedProvider = try WebDAVCloudProvider(client: .mocked(baseURL: baseURL, protocolClass: RecordingURLProtocolAuthenticationMock.self))
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try getTestData(forResource: "item-data", withExtension: "txt").write(to: localURL)

			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let failureResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
			let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
			URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
			await #expect(throws: CloudProviderError.unauthorized) { try await unauthorizedProvider.uploadFile(from: localURL, to: CloudPath("/Documents/About.txt"), replaceExisting: false) }
			#expect(RecordingURLProtocolAuthenticationMock.log.wireSummaries == ["PROPFIND Depth 0 /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
		}

		@Test
		func testCreateFolder() async throws {
			let responseURL = try #require(URL(string: "foo/", relativeTo: baseURL))

			let mkcolResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (mkcolResponse, nil)
			})
			try await provider.createFolder(at: CloudPath("/foo"))
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["MKCOL /cloud/remote.php/webdav/foo"])
		}

		@Test
		func createFolderWithAlreadyExistsError() async throws {
			let responseURL = try #require(URL(string: "foo/", relativeTo: baseURL))

			let mkcolResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (mkcolResponse, nil)
			})
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.createFolder(at: CloudPath("/foo")) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["MKCOL /cloud/remote.php/webdav/foo"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func createFolderWithParentFolderDoesNotExistError() async throws {
			let responseURL = try #require(URL(string: "foo/", relativeTo: baseURL))

			let mkcolResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (mkcolResponse, nil)
			})
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.createFolder(at: CloudPath("/foo")) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["MKCOL /cloud/remote.php/webdav/foo"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func createFolderWithUnauthorizedError() async throws {
			let unauthorizedProvider = try WebDAVCloudProvider(client: .mocked(baseURL: baseURL, protocolClass: RecordingURLProtocolAuthenticationMock.self))

			let responseURL = try #require(URL(string: "foo/", relativeTo: baseURL))
			let failureResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
			let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
			URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
			await #expect(throws: CloudProviderError.unauthorized) { try await unauthorizedProvider.createFolder(at: CloudPath("/foo")) }
			#expect(RecordingURLProtocolAuthenticationMock.log.wireSummaries == ["MKCOL /cloud/remote.php/webdav/foo"])
			#expect(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
		}

		/// RFC 4918 lists no 404 for MKCOL, so it passes through raw.
		@Test
		func createFolderWithNotFoundError() async throws {
			try enqueueResponse(statusCode: 404, for: #require(URL(string: "foo/", relativeTo: baseURL)))

			await #expect(throws: WebDAVError.httpError(statusCode: 404)) { try await provider.createFolder(at: CloudPath("/foo")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A read-only share answers 403, which editing the account wouldn't fix.
		@Test
		func createFolderWithForbiddenError() async throws {
			try enqueueResponse(statusCode: 403, for: #require(URL(string: "foo/", relativeTo: baseURL)))

			await #expect(throws: WebDAVError.httpError(statusCode: 403)) { try await provider.createFolder(at: CloudPath("/foo")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func testDeleteFile() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let deleteResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (deleteResponse, nil)
			})
			try await provider.deleteFile(at: CloudPath("/Documents/About.txt"))
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["DELETE /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func deleteFileWithNotFoundError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let deleteResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (deleteResponse, nil)
			})

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.deleteFile(at: CloudPath("/Documents/About.txt")) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["DELETE /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func deleteFileWithUnauthorizedError() async throws {
			let unauthorizedProvider = try WebDAVCloudProvider(client: .mocked(baseURL: baseURL, protocolClass: RecordingURLProtocolAuthenticationMock.self))

			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let failureResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
			let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
			URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
			await #expect(throws: CloudProviderError.unauthorized) { try await unauthorizedProvider.deleteFile(at: CloudPath("/Documents/About.txt")) }
			#expect(RecordingURLProtocolAuthenticationMock.log.wireSummaries == ["DELETE /cloud/remote.php/webdav/Documents/About.txt"])
			#expect(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
		}

		/// See the rationale on the forbidden create folder variant.
		@Test
		func deleteFileWithForbiddenError() async throws {
			try enqueueResponse(statusCode: 403, for: #require(URL(string: "Documents/About.txt", relativeTo: baseURL)))

			await #expect(throws: WebDAVError.httpError(statusCode: 403)) { try await provider.deleteFile(at: CloudPath("/Documents/About.txt")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A server answers with 207 when a collection's DELETE failed for some members (RFC 4918, section 9.6.1). The fixture declares `DAV:` as the default namespace, which the parser has to resolve.
		@Test
		func deleteFolderWithFailedMember() async throws {
			let data = try getTestData(forResource: "collection-207-failed-member", withExtension: "xml")
			try enqueueResponse(statusCode: 207, data: data, for: #require(URL(string: "Documents", relativeTo: baseURL)))

			await #expect(throws: CloudProviderError.deletionIncomplete) { try await provider.deleteFolder(at: CloudPath("/Documents")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A 207 whose members all have a 2xx status means that the whole folder was deleted.
		@Test
		func deleteFolderWithSucceededMembers() async throws {
			let data = try getTestData(forResource: "collection-207-succeeded-members", withExtension: "xml")
			try enqueueResponse(statusCode: 207, data: data, for: #require(URL(string: "Documents", relativeTo: baseURL)))

			try await provider.deleteFolder(at: CloudPath("/Documents"))
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func deleteFolderWithMalformedMultistatus() async throws {
			try enqueueResponse(statusCode: 207, data: Data("<d:multistatus xmlns:d=\"DAV:\"><d:response>".utf8), for: #require(URL(string: "Documents", relativeTo: baseURL)))

			await #expect(throws: WebDAVError.unexpectedResponse) { try await provider.deleteFolder(at: CloudPath("/Documents")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func testMoveFile() async throws {
			let baseURL = try #require(URL(string: "https://example.com/cloud/remote.php/webdav/"))
			let provider = try WebDAVCloudProvider(client: .mocked(baseURL: baseURL))
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let moveResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (moveResponse, nil)
			})

			try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt"))
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["MOVE Overwrite F /cloud/remote.php/webdav/Documents/About.txt -> https://example.com/cloud/remote.php/webdav/Documents/Foobar.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A name with characters that a URL path must escape reaches the server percent-encoded, in the path and in the `Destination`. Unescaped, `#` would start a fragment and `?` a query.
		@Test
		func moveFileWithNamesThatNeedPercentEncoding() async throws {
			try enqueueResponse(statusCode: 201, for: #require(URL(cloudPath: CloudPath("/a #b%20.txt"), relativeTo: baseURL)))

			try await provider.moveFile(from: CloudPath("/a #b%20.txt"), to: CloudPath("/c?d.txt"))
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["MOVE Overwrite F /cloud/remote.php/webdav/a%20%23b%2520.txt -> /cloud/remote.php/webdav/c%3Fd.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func moveFileWithNotFoundError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let moveResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (moveResponse, nil)
			})

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["MOVE Overwrite F /cloud/remote.php/webdav/Documents/About.txt -> /cloud/remote.php/webdav/Documents/Foobar.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func moveFileWithAlreadyExistsError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let moveData = try getTestData(forResource: "item-move-412-error", withExtension: "xml")
			let moveResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 412, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (moveResponse, moveData)
			})

			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["MOVE Overwrite F /cloud/remote.php/webdav/Documents/About.txt -> /cloud/remote.php/webdav/Documents/Foobar.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func moveFileWithParentFolderDoesNotExistError() async throws {
			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))

			let moveResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return (moveResponse, nil)
			})

			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")) }
			#expect(RecordingURLProtocolMock.log.wireSummaries == ["MOVE Overwrite F /cloud/remote.php/webdav/Documents/About.txt -> /cloud/remote.php/webdav/Documents/Foobar.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func moveFileWithUnauthorizedError() async throws {
			let unauthorizedProvider = try WebDAVCloudProvider(client: .mocked(baseURL: baseURL, protocolClass: RecordingURLProtocolAuthenticationMock.self))

			let responseURL = try #require(URL(string: "Documents/About.txt", relativeTo: baseURL))
			let failureResponse = try #require(HTTPURLResponse(url: responseURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil))
			let challenge = URLAuthenticationChallengeMock(previousFailureCount: 1, failureResponse: failureResponse)
			URLProtocolAuthenticationMock.authenticationChallenges.append(challenge)
			await #expect(throws: CloudProviderError.unauthorized) { try await unauthorizedProvider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")) }
			#expect(RecordingURLProtocolAuthenticationMock.log.wireSummaries == ["MOVE Overwrite F /cloud/remote.php/webdav/Documents/About.txt -> /cloud/remote.php/webdav/Documents/Foobar.txt"])
			#expect(URLProtocolAuthenticationMock.authenticationChallenges.isEmpty)
		}

		@Test
		func moveFileWithNoInternetConnectionError() async throws {
			URLProtocolMock.requestHandler.append({ _ in
				throw URLError(.notConnectedToInternet)
			})

			await #expect(throws: CloudProviderError.noInternetConnection) { try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// See the rationale on the forbidden create folder variant.
		@Test
		func moveFileWithForbiddenError() async throws {
			try enqueueResponse(statusCode: 403, for: #require(URL(string: "Documents/About.txt", relativeTo: baseURL)))

			await #expect(throws: WebDAVError.httpError(statusCode: 403)) { try await provider.moveFile(from: CloudPath("/Documents/About.txt"), to: CloudPath("/Documents/Foobar.txt")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A server answers with 207 when a collection's MOVE failed for some members (RFC 4918, section 9.9.4). The move throws the status of the failed member.
		@Test
		func moveFolderWithFailedMember() async throws {
			let data = try getTestData(forResource: "collection-207-failed-member", withExtension: "xml")
			try enqueueResponse(statusCode: 207, data: data, for: #require(URL(string: "Documents", relativeTo: baseURL)))

			await #expect(throws: WebDAVError.httpError(statusCode: 423)) { try await provider.moveFolder(from: CloudPath("/Documents"), to: CloudPath("/Archive")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func throwsCancellationErrorInCancelledTask() async {
			await assertThrowsCancellationErrorInCancelledTask(provider)
			#expect(RecordingURLProtocolMock.log.wireSummaries == [])
		}

		// MARK: - Internal

		/// The names of the children in `item-list.xml`.
		private static let itemListNames = ["Documents", "Nextcloud Manual.pdf", "Nextcloud intro.mp4", "Nextcloud.png", "Photos"].sorted()

		private func removingResponse(withHref href: String, from data: Data) throws -> Data {
			let document = try #require(String(data: data, encoding: .utf8))
			let hrefRange = try #require(document.range(of: "<d:href>\(href)</d:href>"))
			let responseStart = try #require(document.range(of: "<d:response>", options: .backwards, range: document.startIndex ..< hrefRange.lowerBound))
			let responseEnd = try #require(document.range(of: "</d:response>", range: hrefRange.upperBound ..< document.endIndex))
			return Data(document.replacingCharacters(in: responseStart.lowerBound ..< responseEnd.upperBound, with: "").utf8)
		}

		/// A listing whose first element has one attribute more than the cap, followed by a malformed tail.
		private func listingWithTooManyAttributes(value: String) throws -> Data {
			let document = try #require(String(data: getMultistatusData(forHrefs: [baseURL.path + "/", baseURL.path + "/a.txt"]), encoding: .utf8))
				.replacing("<d:response>", with: "<d:response \(attributesOverCap(value: value))>", maxReplacements: 1)
				.replacing("</d:multistatus>", with: "</d:propstat></d:multistatus>")
			return Data(document.utf8)
		}

		private func getTestData(forResource name: String, withExtension ext: String) throws -> Data {
			let testBundle = Bundle.module
			guard let fileURL = testBundle.url(forResource: name, withExtension: ext) else {
				throw WebDAVProviderTestsError.missingTestResource
			}
			return try Data(contentsOf: fileURL)
		}

		private func enqueueResponse(statusCode: Int, data: Data? = nil, for responseURL: URL, onRequest: @escaping @Sendable () -> Void = {}) throws {
			let response = try #require(HTTPURLResponse(url: responseURL, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil))
			URLProtocolMock.requestHandler.append({ request in
				guard let url = request.url, url.path == responseURL.path else {
					throw URLProtocolMockError.unexpectedRequest
				}
				onRequest()
				return (response, data)
			})
		}

		private func makeGatedProvider() throws -> (WebDAVCloudProvider, TransferGate) {
			let credential = WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil)
			let gate = TransferGate()
			let configuration = URLSessionConfiguration.default
			configuration.httpCookieStorage = HTTPCookieStorage()
			configuration.urlCredentialStorage = nil
			configuration.protocolClasses = [URLProtocolSequenceMock.self]
			let client = WebDAVClient(credential: credential, session: WebDAVSession(credential: credential, configuration: configuration, metadataConfiguration: nil, hooks: gate.hooks))
			let provider = try WebDAVCloudProvider(client: client)
			return (provider, gate)
		}
	}
}

/// Keeps the request that `FirstRequestHoldingProtocolMock` takes unanswered until `release()`. Without a release, the test's wait for the listing or the request's timeout fails the test.
private final class RequestHold: Sendable {
	private struct State {
		var loading: HeldLoading?
		var isReleased = false
	}

	let reached = TestSignal("held request reached the mock")
	private let state = OSAllocatedUnfairLock(initialState: State())

	func release() {
		let loading = state.withLock { state in
			state.isReleased = true
			return state.loading
		}
		loading?.answer()
	}

	/// Keeps the loading until `release()`, and returns `false` if the hold was released already, so that the caller answers at once.
	fileprivate func hold(_ loading: HeldLoading) -> Bool {
		return state.withLock { state in
			if !state.isReleased {
				state.loading = loading
			}
			return !state.isReleased
		}
	}
}

/// Holds the first request that arrives once the test armed a hold, without blocking its loading thread, so that the session's other requests still complete.
private final class FirstRequestHoldingProtocolMock: URLProtocolMock {
	private static let pendingHold = OSAllocatedUnfairLock<RequestHold?>(initialState: nil)

	/// Set once the loading stopped, e.g. because its task was cancelled, after which it must not call back anymore. Read and written only on the loading thread.
	fileprivate var isStopped = false

	static func arm(_ hold: RequestHold) {
		pendingHold.withLock { $0 = hold }
	}

	static func takePendingHold() -> RequestHold? {
		return pendingHold.withLock { hold in
			defer { hold = nil }
			return hold
		}
	}

	override func startLoading() {
		guard let hold = FirstRequestHoldingProtocolMock.takePendingHold() else {
			super.startLoading()
			return
		}
		let isHeld = hold.hold(HeldLoading(protocolInstance: self, runLoop: CFRunLoopGetCurrent()))
		hold.reached.fulfill()
		if !isHeld {
			answerHeldRequest()
		}
	}

	override func stopLoading() {
		isStopped = true
	}

	fileprivate func answerHeldRequest() {
		if !isStopped {
			super.startLoading()
		}
	}
}

/// `@unchecked Sendable`: `runLoop` is only passed to `CFRunLoopPerformBlock` and `CFRunLoopWakeUp`, which may be called from any thread. `protocolInstance` is used only inside the block posted to that run loop.
private final class HeldLoading: @unchecked Sendable {
	private let protocolInstance: FirstRequestHoldingProtocolMock
	private let runLoop: CFRunLoop

	init(protocolInstance: FirstRequestHoldingProtocolMock, runLoop: CFRunLoop) {
		self.protocolInstance = protocolInstance
		self.runLoop = runLoop
	}

	/// Answers on the loading thread.
	func answer() {
		CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [protocolInstance] in
			protocolInstance.answerHeldRequest()
		}
		CFRunLoopWakeUp(runLoop)
	}
}

/// Holds back the terminal processing of a transfer task until the test opens the gate, so that a test can observe whether a call already returned while its task is still running.
private final class TransferGate: Sendable {
	let challengeRejected = TestSignal("authentication challenge rejected")
	let completionGate = DispatchSemaphore(value: 0)

	var hooks: SplitURLSession.Hooks {
		return SplitURLSession.Hooks(didApplyChallengeDecision: { [challengeRejected] task, decision in
			if decision.disposition == .cancelAuthenticationChallenge, TransferGate.isTransfer(task) {
				challengeRejected.fulfill()
			}
		}, willProcessCompletion: { [completionGate] task in
			if TransferGate.isTransfer(task) {
				_ = completionGate.wait(timeout: testWaitDeadline())
			}
		})
	}

	private static func isTransfer(_ task: URLSessionTask) -> Bool {
		return task is URLSessionUploadTask || task is URLSessionDownloadTask
	}
}
