//
//  WebDAVClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 18.11.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class WebDAVClientTests: XCTestCase {
	func testSanitizeBaseURLWithMissingTrailingSlash() throws {
		let credential = try WebDAVCredential(baseURL: XCTUnwrap(URL(string: "/cloud/remote.php/webdav")), username: "", password: "", allowedCertificate: nil)
		let delegate = WebDAVClientURLSessionDelegate(credential: credential)
		let configuration = URLSessionConfiguration.default
		let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		let client = WebDAVClient(credential: credential, session: WebDAVSession(urlSession: urlSession, delegate: delegate))
		XCTAssertEqual(URL(string: "/cloud/remote.php/webdav/"), client.baseURL)
	}

	func testSanitizeBaseURLWithTrailingSlash() throws {
		let credential = try WebDAVCredential(baseURL: XCTUnwrap(URL(string: "/cloud/remote.php/webdav/")), username: "", password: "", allowedCertificate: nil)
		let delegate = WebDAVClientURLSessionDelegate(credential: credential)
		let configuration = URLSessionConfiguration.default
		let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		let client = WebDAVClient(credential: credential, session: WebDAVSession(urlSession: urlSession, delegate: delegate))
		XCTAssertEqual(URL(string: "/cloud/remote.php/webdav/"), client.baseURL)
	}

	/// Metadata/control operations must ride the foreground data session and file transfers the background
	/// transfer session, because Apple's background `URLSession`s support only upload/download tasks. The two
	/// sessions are stood up with distinct recording `URLProtocol`s so the routing can be asserted directly.
	func testRoutesControlOperationsToDataSessionAndTransfersToTransferSession() async throws {
		RecordingURLProtocolMock.reset()
		defer { RecordingURLProtocolMock.reset() }

		let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tmpDirURL) }

		let baseURL = try XCTUnwrap(URL(string: "/cloud/remote.php/webdav/"))
		let credential = WebDAVCredential(baseURL: baseURL, username: "", password: "", allowedCertificate: nil)
		let delegate = WebDAVClientURLSessionDelegate(credential: credential)

		let dataConfiguration = URLSessionConfiguration.default
		dataConfiguration.protocolClasses = [DataSessionURLProtocolMock.self]
		let dataSession = URLSession(configuration: dataConfiguration, delegate: delegate, delegateQueue: nil)

		let transferConfiguration = URLSessionConfiguration.default
		transferConfiguration.protocolClasses = [TransferSessionURLProtocolMock.self]
		let transferSession = URLSession(configuration: transferConfiguration, delegate: delegate, delegateQueue: nil)

		let session = WebDAVSession(dataSession: dataSession, transferSession: transferSession, delegate: delegate)
		let client = WebDAVClient(credential: credential, session: session)

		let remoteURL = try XCTUnwrap(URL(string: "Documents/About.txt", relativeTo: baseURL))
		let moveDestinationURL = try XCTUnwrap(URL(string: "Documents/About-moved.txt", relativeTo: baseURL))
		let propfindDestinationURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let getDestinationURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let uploadSourceURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try Data().write(to: uploadSourceURL)

		_ = try await client.OPTIONS(url: remoteURL).async()
		_ = try await client.HEAD(url: remoteURL).async()
		_ = try await client.PROPFIND(url: remoteURL, depth: .one).async()
		_ = try await client.PROPFIND(url: remoteURL, depth: .one, to: propfindDestinationURL).async()
		_ = try await client.MKCOL(url: remoteURL).async()
		_ = try await client.DELETE(url: remoteURL).async()
		_ = try await client.MOVE(sourceURL: remoteURL, destinationURL: moveDestinationURL).async()
		_ = try await client.GET(from: remoteURL, to: getDestinationURL, onTaskCreation: nil).async()
		_ = try await client.PUT(url: remoteURL, fileURL: uploadSourceURL, onTaskCreation: nil).async()

		XCTAssertEqual(["OPTIONS", "HEAD", "PROPFIND", "PROPFIND", "MKCOL", "DELETE", "MOVE"], RecordingURLProtocolMock.recordedMethods(for: DataSessionURLProtocolMock.self))
		XCTAssertEqual(["GET", "PUT"], RecordingURLProtocolMock.recordedMethods(for: TransferSessionURLProtocolMock.self))
	}
}
