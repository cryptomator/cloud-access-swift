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
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
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

		@Test
		func testBackgroundConfiguration() {
			let configuration = WebDAVSession.backgroundConfiguration(sessionIdentifier: "WebDAVClientTests", sharedContainerIdentifier: "group.test")

			#expect(configuration.identifier == "WebDAVClientTests")
			#expect(configuration.sharedContainerIdentifier == "group.test")
		}

		@Test
		func configurationsAreHardened() {
			for configuration in [WebDAVSession.foregroundConfiguration(), WebDAVSession.backgroundConfiguration(sessionIdentifier: "WebDAVClientTests", sharedContainerIdentifier: nil)] {
				#expect(configuration.urlCache == nil)
				#expect(configuration.urlCredentialStorage == nil)
				#expect(configuration.httpCookieStorage != nil)
				#expect(!(configuration.httpCookieStorage === HTTPCookieStorage.shared))
			}
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
			}, count: 9)
			let fileURL = baseURL.appendingPathComponent("file.txt")
			let uploadURL = tmpDirURL.appendingPathComponent("upload.txt")
			try Data("content".utf8).write(to: uploadURL)

			_ = try await client.OPTIONS(url: baseURL)
			_ = try await client.HEAD(url: fileURL)
			_ = try await client.PROPFIND(url: fileURL, depth: .zero)
			_ = try await client.PROPFIND(url: baseURL, depth: .one, to: tmpDirURL.appendingPathComponent("listing.xml"))
			_ = try await client.MKCOL(url: baseURL.appendingPathComponent("folder"))
			_ = try await client.DELETE(url: fileURL)
			_ = try await client.MOVE(sourceURL: fileURL, destinationURL: baseURL.appendingPathComponent("moved.txt"))
			_ = try await client.GET(from: fileURL, to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)
			_ = try await client.PUT(url: fileURL, fileURL: uploadURL, progress: nil, onTaskCreation: nil)

			#expect(sessions.withLock { $0 } == [
				"OPTIONS ": "metadata",
				"HEAD ": "metadata",
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
			let client = makeSequenceClient()
			URLProtocolSequenceMock.steps = [.failure(URLError(.serverCertificateUntrusted))]

			let error = try await #require(throws: (any Error).self) { try await client.PROPFIND(url: baseURL, depth: .zero) }
			#expect(URLError.serverCertificateUntrusted == (error as? URLError)?.code, "Unexpected error: \(error)")
		}

		@Test
		func responseBodyOverLimitThrowsUnexpectedResponse() async throws {
			let client = makeSequenceClient()
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 207, httpVersion: nil, headerFields: nil))
			URLProtocolSequenceMock.steps = [.chunkedResponse(response, [Data(count: 1024 * 1024), Data(count: 1)])]

			await #expect(throws: WebDAVError.unexpectedResponse) { try await client.PROPFIND(url: baseURL, depth: .zero) }
		}

		@Test
		func uploadResponseBodyOverLimitThrowsUnexpectedResponse() async throws {
			let client = makeSequenceClient()
			let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
			try Data("content".utf8).write(to: fileURL)
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 201, httpVersion: nil, headerFields: nil))
			URLProtocolSequenceMock.steps = [.chunkedResponse(response, [Data(count: 1024 * 1024), Data(count: 1)])]

			await #expect(throws: WebDAVError.unexpectedResponse) { try await client.PUT(url: baseURL.appendingPathComponent("file.txt"), fileURL: fileURL, progress: nil, onTaskCreation: nil) }
		}

		@Test
		func transportErrorWithSuccessfulResponseIsThrownWithoutURL() throws {
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil))
			let outcome = SplitURLSession.Outcome(response: response, body: .none, error: URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: baseURL]), recordedFailure: nil)

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
			let location = tmpDirURL.appendingPathComponent("location")
			try Data("not found".utf8).write(to: location)

			let body = try WebDAVSession.downloadHandler(movingTo: tmpDirURL.appendingPathComponent("download.txt"))(location, response)

			#expect(SplitURLSession.Outcome.Body.none == body)
			#expect(FileManager.default.fileExists(atPath: location.path))
			#expect(throws: WebDAVError.httpError(statusCode: 404)) { try WebDAVSession.successfulDownloadResponse(of: SplitURLSession.Outcome(response: response, body: body, error: nil, recordedFailure: nil)) }
		}

		@Test
		func failedMoveTakesPrecedenceOverStatus() throws {
			let response = try #require(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil))
			let location = tmpDirURL.appendingPathComponent("location")
			let localURL = tmpDirURL.appendingPathComponent("download.txt")
			try Data("content".utf8).write(to: location)
			try Data("existing".utf8).write(to: localURL)

			let moveError = try #require(throws: (any Error).self) { try WebDAVSession.downloadHandler(movingTo: localURL)(location, response) }
			let failedResponse = try #require(HTTPURLResponse(url: baseURL, statusCode: 500, httpVersion: nil, headerFields: nil))
			let outcome = SplitURLSession.Outcome(response: failedResponse, body: .none, error: nil, recordedFailure: moveError)

			let error = try #require(throws: (any Error).self) { try WebDAVSession.successfulDownloadResponse(of: outcome) }
			#expect((moveError as NSError) == (error as NSError))
			#expect(try Data("existing".utf8) == Data(contentsOf: localURL))
		}

		// MARK: - Helpers

		private func makeSequenceClient() -> WebDAVClient {
			let credential = WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil)
			let configuration = URLSessionConfiguration.default
			configuration.protocolClasses = [URLProtocolSequenceMock.self]
			return WebDAVClient(credential: credential, session: WebDAVSession(credential: credential, configuration: configuration, metadataConfiguration: nil))
		}
	}
}
