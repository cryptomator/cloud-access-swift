//
//  BoxClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class BoxClientTests {
		private let tokenSource: OAuthTokenSourceStub
		private let sleeps: SleepRecorder
		private let client: BoxClient
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.tokenSource = OAuthTokenSourceStub()
			self.sleeps = SleepRecorder()
			self.client = BoxClient.mocked(tokenSource: tokenSource, sleeps: sleeps)
			self.tmpDirURL = try makeTemporaryDirectory()
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		// MARK: - Retries

		@Test
		func throttledRequestWaitsForLowercaseRetryAfter() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 429, headerFields: ["retry-after": "2"]),
				URLProtocolMock.handler(body: BoxMockResponse.user)
			]

			_ = try await client.user()

			#expect([.seconds(2)] == sleeps.durations)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func finalServerErrorKeepsCodeAndMessage() async throws {
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 503, body: #"{"code":"unavailable","message":"Unavailable"}"#), count: 6)

			await #expect(throws: BoxError.apiError(statusCode: 503, code: "unavailable", message: "Unavailable")) { try await client.user() }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func unauthorizedRequestIsRetriedOnceWithRefreshedToken() async throws {
			let authorizations = OSAllocatedUnfairLock(initialState: [String?]())
			let recordAuthorization: @Sendable (URLRequest) -> Void = { request in
				authorizations.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 401, onRequest: recordAuthorization),
				URLProtocolMock.handler(body: BoxMockResponse.user, onRequest: recordAuthorization)
			]

			_ = try await client.user()

			#expect(authorizations.withLock { $0 } == ["Bearer TOKEN", "Bearer REFRESHED"])
			#expect(tokenSource.rejectedTokens == ["TOKEN"])
			#expect(sleeps.durations.isEmpty)

			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(body: BoxMockResponse.user)]

			await #expect(throws: BoxError.apiError(statusCode: 401, code: nil, message: nil)) { try await client.user() }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func transportErrorsAreRetriedOnlyForGet() async throws {
			URLProtocolMock.requestHandler = [{ _ in throw URLError(.timedOut) }, URLProtocolMock.handler(body: BoxMockResponse.user)]

			_ = try await client.user()

			#expect(sleeps.durations.count == 1)
			#expect(URLProtocolMock.requestHandler.isEmpty)

			URLProtocolMock.requestHandler = [{ _ in throw URLError(.timedOut) }, URLProtocolMock.handler(body: BoxMockResponse.folderEntry(id: "1", name: "folder"))]

			let error = try await #require(throws: (any Error).self) { try await client.createFolder(name: "folder", parentID: "0") }
			#expect((error as? URLError)?.code == .timedOut)
			#expect(URLProtocolMock.requestHandler.count == 1)

			URLProtocolMock.requestHandler = [{ _ in throw URLError(.notConnectedToInternet) }]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await client.user() }
		}

		@Test
		func commitThatStaysNotReadyThrowsFileNotReady() async throws {
			URLProtocolMock.requestHandler = Array(repeating: URLProtocolMock.handler(statusCode: 202, headerFields: ["Retry-After": "1"]), count: 5)

			await #expect(throws: BoxError.fileNotReady) { try await client.commit(url: "https://upload.box.com/api/2.0/files/upload_sessions/S/commit", parts: [], digest: "sha=") }
			#expect(URLProtocolMock.requestHandler.isEmpty)
			#expect(sleeps.durations.count == 4)
		}

		@Test
		func metadataBodyOverLimitFails() async throws {
			URLProtocolMock.requestHandler = [{ request in
				(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
			}]

			let error = try await #require(throws: (any Error).self) { try await client.user() }
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		// MARK: - Requests

		@Test
		func metadataRequestsAndTransfersRunOnTheirSessions() async throws {
			let client = BoxClient(tokenSource: tokenSource, configuration: URLProtocolMock.configuration(marker: "transfer"), metadataConfiguration: URLProtocolMock.configuration(marker: "metadata"), sleep: { [sleeps] in sleeps.sleep(for: $0) })
			let markers = OSAllocatedUnfairLock(initialState: [String?]())
			let recordMarker: @Sendable (URLRequest) -> Void = { request in
				markers.withLock { $0.append(request.value(forHTTPHeaderField: "X-Session")) }
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: BoxMockResponse.folderEntry(id: "7", name: "folder"), onRequest: recordMarker),
				URLProtocolMock.handler(body: "content", onRequest: recordMarker)
			]

			_ = try await client.folder(id: "7")
			try await client.download(fileID: "5", to: tmpDirURL.appending(component: "download", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil)

			#expect(markers.withLock { $0 } == ["metadata", "transfer"])
		}

		@Test
		func listingSendsFieldsAndEscapedMarker() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"entries":[]}"#, onRequest: requests.record)]

			_ = try await client.folderItems(id: "7", marker: "a+b c", limit: 100)

			let url = try #require(requests.requests.first?.url)
			#expect(url.scheme == "https")
			#expect(url.host == "api.box.com")
			#expect(url.path == "/2.0/folders/7/items")
			let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
			let query = try #require(components.percentEncodedQuery)
			#expect(query.contains("marker=a%2Bb%20c"), "\(query)")
			#expect(try URLProtocolMock.queryParameters(of: components) == ["fields": "name,size,modified_at", "usemarker": "true", "marker": "a+b c", "limit": "100"])
		}

		/// Box sends nothing before a recursive folder delete is done, so the request's timeout exceeds the 600 s after which Box gives up.
		@Test
		func recursiveFolderDeleteWaitsLongerThanBoxTimeLimit() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)]

			try await client.deleteFolder(id: "7")

			let request = try #require(requests.requests.first)
			#expect(request.url?.path == "/2.0/folders/7")
			#expect(request.url?.query == "recursive=true")
			#expect(request.timeoutInterval > 600)
		}

		@Test
		func uploadSessionURLOutsideBoxIsRejectedWithoutRequest() async throws {
			let partFileURL = try makeLocalFile(in: tmpDirURL, named: "part", content: "part")

			for url in ["https://evil.example/upload", "http://upload.box.com/api/2.0/files/upload_sessions/S", "https://evilbox.com/upload"] {
				await #expect(throws: BoxError.unexpectedContent, "\(url)") { try await client.uploadPart(url: url, from: partFileURL, range: 0 ... 3, fileSize: 4, digest: "sha=", progress: nil) }
			}
		}

		// MARK: - Logging

		@Test
		func responseBodiesAreNotLogged() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let fileURL = try makeLocalFile(in: tmpDirURL, named: "upload")
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"type":"user","id":"USER-ID","name":"User","login":"secret@example.com"}"#),
				URLProtocolMock.handler(body: #"{"type":"folder","id":"7","name":"folder","owned_by":{"login":"owner@example.com"}}"#),
				URLProtocolMock.handler(statusCode: 201, body: #"{"entries":[{"type":"file","id":"9","name":"file.txt","size":7,"owned_by":{"login":"uploader@example.com"}}]}"#)
			]

			let user = try await client.user()
			_ = try await client.folder(id: "7")
			_ = try await client.uploadNewFile(from: fileURL, name: "file.txt", parentID: "7", progress: nil, onTaskCreation: nil)

			#expect(user.name == "User")
			let log = logCapture.joinedMessages
			#expect(log.contains("https://api.box.com"), "\(log)")
			#expect(log.contains("https://upload.box.com"), "\(log)")
			for email in ["secret@example.com", "owner@example.com", "uploader@example.com"] {
				#expect(!log.contains(email), "\(email) in \(log)")
			}
		}

		@Test
		func downloadLogsAPIPathAndOnlyOriginOfRedirectTarget() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "https://dl.boxcloud.com/d/1/SECRET-PATH/file.txt"]),
				URLProtocolMock.handler(body: "content")
			]
			let stagingURL = tmpDirURL.appending(component: "download", directoryHint: .notDirectory)

			try await client.download(fileID: "5", to: stagingURL, progress: nil, onTaskCreation: nil)

			#expect(try Data("content".utf8) == Data(contentsOf: stagingURL))
			let log = logCapture.joinedMessages
			#expect(logCapture.messages.contains("--> GET https://api.box.com/2.0/files/5/content"), "\(log)")
			#expect(logCapture.messages.contains("<-- 200 no error https://dl.boxcloud.com/<redacted>"), "\(log)")
			for secret in ["SECRET-PATH", "TOKEN"] {
				#expect(!log.contains(secret), "\(secret) in \(log)")
			}
		}

		@Test
		func bodiesOfDownloadsAreNotLogged() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "https://dl.boxcloud.com/d/1/PATH/file.txt"]),
				URLProtocolMock.handler(statusCode: 404, body: "<Error>https://dl.boxcloud.com/d/1/SECRET-PATH/file.txt</Error>")
			]

			await #expect(throws: BoxError.apiError(statusCode: 404, code: nil, message: nil)) { try await client.download(fileID: "5", to: tmpDirURL.appending(component: "download", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil) }

			#expect(logCapture.messages.contains { $0.hasPrefix("<-- 404 ") && $0.contains("https://dl.boxcloud.com") }, "\(logCapture.joinedMessages)")
			#expect(!logCapture.joinedMessages.contains("SECRET"), "\(logCapture.joinedMessages)")
		}

		@Test
		func errorMessageFromAnotherOriginIsDropped() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "https://dl.boxcloud.com/d/1/PATH/file.txt"]),
				URLProtocolMock.handler(statusCode: 404, body: #"{"type":"error","status":404,"code":"not_found","message":"https://dl.boxcloud.com/d/1/SECRET-PATH/file.txt"}"#)
			]

			await #expect(throws: BoxError.apiError(statusCode: 404, code: "not_found", message: nil)) { try await client.download(fileID: "5", to: tmpDirURL.appending(component: "download", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil) }
		}
	}
}

extension BoxClient {
	static func mocked(tokenSource: any BearerTokenSource = OAuthTokenSourceStub(), sleeps: SleepRecorder = SleepRecorder(), hooks: SplitURLSession.Hooks = SplitURLSession.Hooks()) -> BoxClient {
		return BoxClient(tokenSource: tokenSource, configuration: URLProtocolMock.configuration(), metadataConfiguration: nil, hooks: hooks, sleep: { sleeps.sleep(for: $0) })
	}
}

enum BoxMockResponse {
	static let user = #"{"type":"user","id":"USER-ID","name":"User"}"#
	static let modifiedAt = "2026-10-20T11:05:00-07:00"

	/// An entry in the folder `parentID`, or without a folder if it is `nil`.
	static func fileEntry(id: String, name: String, size: Int = 7, modifiedAt: String = modifiedAt, parentID: String? = "0") -> String {
		let parent = parentID.map { #","parent":{"type":"folder","id":"\#($0)"}"# } ?? ""
		return #"{"type":"file","id":"\#(id)","name":"\#(name)","size":\#(size),"modified_at":"\#(modifiedAt)"\#(parent)}"#
	}

	static func folderEntry(id: String, name: String) -> String {
		return #"{"type":"folder","id":"\#(id)","name":"\#(name)","size":12,"modified_at":"\#(modifiedAt)"}"#
	}

	static func items(_ entries: [String], nextMarker: String? = nil) -> String {
		return #"{"entries":[\#(entries.joined(separator: ","))]\#(nextMarker.map { #","next_marker":"\#($0)""# } ?? "")}"#
	}

	static func files(_ entries: [String]) -> String {
		return #"{"total_count":\#(entries.count),"entries":[\#(entries.joined(separator: ","))]}"#
	}

	static func error(status: Int, code: String) -> String {
		return #"{"type":"error","status":\#(status),"code":"\#(code)"}"#
	}
}
