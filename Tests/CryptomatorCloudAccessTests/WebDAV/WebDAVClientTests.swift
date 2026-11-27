//
//  WebDAVClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 18.11.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class WebDAVClientTests {
		private let baseURL = URL(string: "https://webdav.example.com/remote.php/webdav/")!
		private let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			URLProtocolSequenceMock.steps = []
			self.tmpDirURL = try makeTemporaryDirectory()
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func sanitizeBaseURLWithMissingTrailingSlash() throws {
			let credential = try WebDAVCredential(baseURL: #require(URL(string: "/cloud/remote.php/webdav")), username: "", password: "", allowedCertificate: nil)
			let client = WebDAVClient(credential: credential, session: WebDAVSession(credential: credential, configuration: .default, metadataConfiguration: .default))
			#expect(URL(string: "/cloud/remote.php/webdav/") == client.baseURL)
		}

		@Test
		func sanitizeBaseURLWithTrailingSlash() throws {
			let credential = try WebDAVCredential(baseURL: #require(URL(string: "/cloud/remote.php/webdav/")), username: "", password: "", allowedCertificate: nil)
			let client = WebDAVClient(credential: credential, session: WebDAVSession(credential: credential, configuration: .default, metadataConfiguration: .default))
			#expect(URL(string: "/cloud/remote.php/webdav/") == client.baseURL)
		}

		// MARK: - Routing

		@Test
		func transfersRunOnTransferSessionAndOtherRequestsOnMetadataSession() async throws {
			let credential = WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil)
			let client = WebDAVClient(credential: credential, session: WebDAVSession(credential: credential, configuration: URLProtocolMock.configuration(marker: "transfer"), metadataConfiguration: URLProtocolMock.configuration(marker: "metadata")))
			let sessions = OSAllocatedUnfairLock(initialState: [String: String]())
			URLProtocolMock.requestHandler = Array(repeating: { request in
				sessions.withLock { $0["\(request.httpMethod ?? "") \(request.value(forHTTPHeaderField: "Depth") ?? "")"] = request.value(forHTTPHeaderField: "X-Session") }
				return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
			}, count: 8)
			let fileURL = baseURL.appending(component: "file.txt", directoryHint: .notDirectory)
			let uploadURL = try makeLocalFile(in: tmpDirURL, named: "upload.txt")

			_ = try await client.OPTIONS(url: baseURL)
			_ = try await client.PROPFIND(url: fileURL, depth: .zero)
			_ = try await client.PROPFIND(url: baseURL, depth: .one, to: tmpDirURL.appending(component: "listing.xml", directoryHint: .notDirectory))
			_ = try await client.MKCOL(url: baseURL.appending(component: "folder", directoryHint: .notDirectory))
			_ = try await client.DELETE(url: fileURL)
			_ = try await client.MOVE(sourceURL: fileURL, destinationURL: baseURL.appending(component: "moved.txt", directoryHint: .notDirectory))
			_ = try await client.GET(from: fileURL, to: tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory), progress: nil, onTaskCreation: nil)
			_ = try await client.PUT(url: fileURL, fileURL: uploadURL, progress: nil, onTaskCreation: nil)

			#expect(sessions.withLock { $0 } == [
				"OPTIONS ": "metadata",
				"PROPFIND 0": "metadata",
				"PROPFIND 1": "metadata",
				"MKCOL ": "metadata",
				"DELETE ": "metadata",
				"MOVE ": "metadata",
				"GET ": "transfer",
				"PUT ": "transfer"
			])
		}

		// MARK: - Errors

		@Test
		func transportErrorWithoutResponseIsThrownUnchanged() async throws {
			let client = WebDAVClient.mocked(baseURL: baseURL, protocolClass: URLProtocolSequenceMock.self)
			URLProtocolSequenceMock.steps = [.failure(URLError(.serverCertificateUntrusted))]

			let error = try await #require(throws: (any Error).self) { try await client.PROPFIND(url: baseURL, depth: .zero) }
			#expect(URLError.serverCertificateUntrusted == (error as? URLError)?.code, "Unexpected error: \(error)")
		}

		@Test
		func responseBodyOverLimitThrowsUnexpectedResponse() async throws {
			let client = WebDAVClient.mocked(baseURL: baseURL, protocolClass: URLProtocolSequenceMock.self)
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 207, httpVersion: nil, headerFields: nil))
			URLProtocolSequenceMock.steps = [.chunkedResponse(response, [Data(count: 1024 * 1024), Data(count: 1)])]

			await #expect(throws: WebDAVError.unexpectedResponse) { try await client.PROPFIND(url: baseURL, depth: .zero) }
		}

		@Test
		func uploadResponseBodyOverLimitThrowsUnexpectedResponse() async throws {
			let client = WebDAVClient.mocked(baseURL: baseURL, protocolClass: URLProtocolSequenceMock.self)
			let fileURL = try makeLocalFile(in: tmpDirURL, named: "upload.txt")
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 201, httpVersion: nil, headerFields: nil))
			URLProtocolSequenceMock.steps = [.chunkedResponse(response, [Data(count: 1024 * 1024), Data(count: 1)])]

			await #expect(throws: WebDAVError.unexpectedResponse) { try await client.PUT(url: baseURL.appending(component: "file.txt", directoryHint: .notDirectory), fileURL: fileURL, progress: nil, onTaskCreation: nil) }
		}

		@Test
		func transportErrorWithSuccessfulResponseIsThrown() throws {
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil))
			let outcome = SplitURLSession.Outcome(response: response, body: .none, error: URLError(.networkConnectionLost), recordedFailure: nil)

			let error = try #require(throws: (any Error).self) { try WebDAVSession.successfulResponse(of: outcome) }
			#expect(URLError(.networkConnectionLost) == (error as? URLError))
		}

		@Test
		func transportErrorWithUnsuccessfulResponseThrowsHTTPError() throws {
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 503, httpVersion: nil, headerFields: nil))
			let outcome = SplitURLSession.Outcome(response: response, body: .none, error: URLError(.networkConnectionLost), recordedFailure: nil)

			#expect(throws: WebDAVError.httpError(statusCode: 503)) { try WebDAVSession.successfulResponse(of: outcome) }
		}

		@Test
		func cancellationTakesPrecedenceOverStatus() throws {
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 503, httpVersion: nil, headerFields: nil))
			let outcome = SplitURLSession.Outcome(response: response, body: .none, error: URLError(.cancelled), recordedFailure: nil)

			#expect(throws: CancellationError.self) { try WebDAVSession.successfulResponse(of: outcome) }
		}

		@Test
		func successfulDownloadWithoutFileThrowsUnexpectedResponse() throws {
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil))
			let outcome = SplitURLSession.Outcome(response: response, body: .none, error: nil, recordedFailure: nil)

			#expect(throws: WebDAVError.unexpectedResponse) { try WebDAVSession.successfulDownloadResponse(of: outcome) }
		}

		@Test
		func unsuccessfulDownloadThrowsHTTPErrorAndLeavesFile() throws {
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 404, httpVersion: nil, headerFields: nil))
			let location = try makeLocalFile(in: tmpDirURL, named: "location", content: "not found")

			let body = try WebDAVSession.downloadHandler(movingTo: tmpDirURL.appending(component: "download.txt", directoryHint: .notDirectory))(location, response)

			#expect(SplitURLSession.Outcome.Body.none == body)
			#expect(FileManager.default.fileExists(atPath: location.path))
			#expect(throws: WebDAVError.httpError(statusCode: 404)) { try WebDAVSession.successfulDownloadResponse(of: SplitURLSession.Outcome(response: response, body: body, error: nil, recordedFailure: nil)) }
		}

		@Test
		func failedMoveTakesPrecedenceOverStatus() throws {
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil))
			let location = try makeLocalFile(in: tmpDirURL, named: "location")
			let localURL = try makeLocalFile(in: tmpDirURL, named: "download.txt", content: "existing")

			let moveError = try #require(throws: (any Error).self) { try WebDAVSession.downloadHandler(movingTo: localURL)(location, response) }
			let failedResponse = try #require(HTTPURLResponse(url: baseURL, statusCode: 500, httpVersion: nil, headerFields: nil))
			let outcome = SplitURLSession.Outcome(response: failedResponse, body: .none, error: nil, recordedFailure: moveError)

			let error = try #require(throws: (any Error).self) { try WebDAVSession.successfulDownloadResponse(of: outcome) }
			#expect((moveError as NSError) == (error as NSError))
			#expect(try Data("existing".utf8) == Data(contentsOf: localURL))
		}
	}
}

extension WebDAVClient {
	/// A client whose requests, transfers included, reach `protocolClass`.
	static func mocked(baseURL: URL, protocolClass: AnyClass = RecordingURLProtocolMock.self) -> WebDAVClient {
		let credential = WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil)
		return WebDAVClient(credential: credential, session: WebDAVSession(credential: credential, configuration: URLProtocolMock.configuration(protocolClass: protocolClass), metadataConfiguration: nil))
	}
}
