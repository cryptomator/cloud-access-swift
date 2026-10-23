//
//  WebDAVClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 18.11.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class WebDAVClientTests: XCTestCase {
	private let baseURL = URL(string: "https://webdav.example.com/remote.php/webdav/")!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		URLProtocolSequenceMock.steps = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testSanitizeBaseURLWithMissingTrailingSlash() throws {
		let credential = try WebDAVCredential(baseURL: XCTUnwrap(URL(string: "/cloud/remote.php/webdav")), username: "", password: "", allowedCertificate: nil)
		let client = WebDAVClient(credential: credential, session: WebDAVSession(credential: credential, configuration: .default, metadataConfiguration: .default))
		XCTAssertEqual(URL(string: "/cloud/remote.php/webdav/"), client.baseURL)
	}

	func testSanitizeBaseURLWithTrailingSlash() throws {
		let credential = try WebDAVCredential(baseURL: XCTUnwrap(URL(string: "/cloud/remote.php/webdav/")), username: "", password: "", allowedCertificate: nil)
		let client = WebDAVClient(credential: credential, session: WebDAVSession(credential: credential, configuration: .default, metadataConfiguration: .default))
		XCTAssertEqual(URL(string: "/cloud/remote.php/webdav/"), client.baseURL)
	}

	func testBackgroundConfiguration() {
		let configuration = WebDAVSession.backgroundConfiguration(sessionIdentifier: "WebDAVClientTests", sharedContainerIdentifier: "group.test")

		XCTAssertEqual("WebDAVClientTests", configuration.identifier)
		XCTAssertEqual("group.test", configuration.sharedContainerIdentifier)
	}

	func testConfigurationsAreHardened() {
		for configuration in [WebDAVSession.foregroundConfiguration(), WebDAVSession.backgroundConfiguration(sessionIdentifier: "WebDAVClientTests", sharedContainerIdentifier: nil)] {
			XCTAssertNil(configuration.urlCache)
			XCTAssertNil(configuration.urlCredentialStorage)
			XCTAssertNotNil(configuration.httpCookieStorage)
			XCTAssertFalse(configuration.httpCookieStorage === HTTPCookieStorage.shared)
		}
	}

	// MARK: - Routing

	func testTransfersRunOnTransferSessionAndOtherRequestsOnMetadataSession() async throws {
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

		XCTAssertEqual([
			"OPTIONS ": "metadata",
			"HEAD ": "metadata",
			"PROPFIND 0": "metadata",
			"PROPFIND 1": "metadata",
			"MKCOL ": "metadata",
			"DELETE ": "metadata",
			"MOVE ": "metadata",
			"GET ": "transfer",
			"PUT ": "transfer"
		], sessions.withLock { $0 })
	}

	// MARK: - Errors

	func testTransportErrorWithoutResponseIsThrownUnchanged() async throws {
		let client = makeSequenceClient()
		URLProtocolSequenceMock.steps = [.failure(URLError(.serverCertificateUntrusted))]

		await XCTAssertThrowsErrorAsync(try await client.PROPFIND(url: baseURL, depth: .zero)) { error in
			XCTAssertEqual(URLError.serverCertificateUntrusted, (error as? URLError)?.code, "Unexpected error: \(error)")
		}
	}

	func testResponseBodyOverLimitThrowsUnexpectedResponse() async throws {
		let client = makeSequenceClient()
		let response = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 207, httpVersion: nil, headerFields: nil))
		URLProtocolSequenceMock.steps = [.chunkedResponse(response, [Data(count: 1024 * 1024), Data(count: 1)])]

		await XCTAssertThrowsErrorAsync(try await client.PROPFIND(url: baseURL, depth: .zero)) { error in
			guard case WebDAVError.unexpectedResponse = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testUploadResponseBodyOverLimitThrowsUnexpectedResponse() async throws {
		let client = makeSequenceClient()
		let fileURL = tmpDirURL.appendingPathComponent("upload.txt")
		try Data("content".utf8).write(to: fileURL)
		let response = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 201, httpVersion: nil, headerFields: nil))
		URLProtocolSequenceMock.steps = [.chunkedResponse(response, [Data(count: 1024 * 1024), Data(count: 1)])]

		await XCTAssertThrowsErrorAsync(try await client.PUT(url: baseURL.appendingPathComponent("file.txt"), fileURL: fileURL, progress: nil, onTaskCreation: nil)) { error in
			guard case WebDAVError.unexpectedResponse = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testTransportErrorWithSuccessfulResponseIsThrownWithoutURL() throws {
		let response = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil))
		let outcome = SplitURLSession.Outcome(response: response, body: .none, error: URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: baseURL]), recordedFailure: nil)

		XCTAssertThrowsError(try WebDAVSession.successfulResponse(of: outcome)) { error in
			XCTAssertEqual(URLError(.networkConnectionLost), error as? URLError)
		}
	}

	func testTransportErrorWithUnsuccessfulResponseThrowsHTTPError() throws {
		let response = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 503, httpVersion: nil, headerFields: nil))
		let outcome = SplitURLSession.Outcome(response: response, body: .none, error: URLError(.networkConnectionLost), recordedFailure: nil)

		XCTAssertThrowsError(try WebDAVSession.successfulResponse(of: outcome)) { error in
			XCTAssertEqual(.httpError(statusCode: 503), error as? WebDAVError)
		}
	}

	func testCancellationTakesPrecedenceOverStatus() throws {
		let response = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 503, httpVersion: nil, headerFields: nil))
		let outcome = SplitURLSession.Outcome(response: response, body: .none, error: URLError(.cancelled), recordedFailure: nil)

		XCTAssertThrowsError(try WebDAVSession.successfulResponse(of: outcome)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
	}

	func testSuccessfulDownloadWithoutFileThrowsUnexpectedResponse() throws {
		let response = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil))
		let outcome = SplitURLSession.Outcome(response: response, body: .none, error: nil, recordedFailure: nil)

		XCTAssertThrowsError(try WebDAVSession.successfulDownloadResponse(of: outcome)) { error in
			guard case WebDAVError.unexpectedResponse = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testUnsuccessfulDownloadThrowsHTTPErrorAndLeavesFile() throws {
		let response = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 404, httpVersion: nil, headerFields: nil))
		let location = tmpDirURL.appendingPathComponent("location")
		try Data("not found".utf8).write(to: location)

		let body = try WebDAVSession.downloadHandler(movingTo: tmpDirURL.appendingPathComponent("download.txt"))(location, response)

		XCTAssertEqual(SplitURLSession.Outcome.Body.none, body)
		XCTAssertTrue(FileManager.default.fileExists(atPath: location.path))
		XCTAssertThrowsError(try WebDAVSession.successfulDownloadResponse(of: SplitURLSession.Outcome(response: response, body: body, error: nil, recordedFailure: nil))) { error in
			XCTAssertEqual(.httpError(statusCode: 404), error as? WebDAVError)
		}
	}

	func testFailedMoveTakesPrecedenceOverStatus() throws {
		let response = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil))
		let location = tmpDirURL.appendingPathComponent("location")
		let localURL = tmpDirURL.appendingPathComponent("download.txt")
		try Data("content".utf8).write(to: location)
		try Data("existing".utf8).write(to: localURL)

		var moveError: Error?
		XCTAssertThrowsError(try WebDAVSession.downloadHandler(movingTo: localURL)(location, response)) { moveError = $0 }
		let failedResponse = try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 500, httpVersion: nil, headerFields: nil))
		let outcome = try SplitURLSession.Outcome(response: failedResponse, body: .none, error: nil, recordedFailure: XCTUnwrap(moveError))

		XCTAssertThrowsError(try WebDAVSession.successfulDownloadResponse(of: outcome)) { error in
			XCTAssertEqual(moveError as NSError?, error as NSError)
		}
		XCTAssertEqual(Data("existing".utf8), try Data(contentsOf: localURL))
	}

	// MARK: - Helpers

	private func makeSequenceClient() -> WebDAVClient {
		let credential = WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil)
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolSequenceMock.self]
		return WebDAVClient(credential: credential, session: WebDAVSession(credential: credential, configuration: configuration, metadataConfiguration: nil))
	}
}
