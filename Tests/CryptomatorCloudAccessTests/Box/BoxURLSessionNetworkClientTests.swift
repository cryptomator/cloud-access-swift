//
//  BoxURLSessionNetworkClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import BoxSdkGen
import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

private final class RefreshingAuthenticationMock: Authentication, Sendable {
	private let token = OSAllocatedUnfairLock(initialState: "expired")

	func retrieveToken(networkSession: NetworkSession?) async throws -> AccessToken {
		return AccessToken(accessToken: token.withLock { $0 })
	}

	func refreshToken(networkSession: NetworkSession?) async throws -> AccessToken {
		token.withLock { $0 = "refreshed" }
		return try await retrieveToken(networkSession: networkSession)
	}

	func retrieveAuthorizationHeader(networkSession: NetworkSession?) async throws -> String {
		return "Bearer \(token.withLock { $0 })"
	}

	func revokeToken(networkSession: NetworkSession?) async throws {}

	func downscopeToken(scopes: [String], resource: String?, sharedLink: String?, networkSession: NetworkSession?) async throws -> AccessToken {
		return AccessToken()
	}
}

class BoxURLSessionNetworkClientTests: XCTestCase {
	private let url = URL(string: "https://api.box.com/2.0/files/content")!
	private var client: BoxURLSessionNetworkClient!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		client = BoxURLSessionNetworkClient(configuration: configuration)
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		client = nil
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testUploadSendsMultipartBody() async throws {
		let recordedBody = OSAllocatedUnfairLock(initialState: Data())
		let responseData = Data("{\"entries\":[]}".utf8)
		URLProtocolMock.requestHandler = [{ [url] request in
			let body = try Utils.readByteStream(byteStream: XCTUnwrap(request.httpBodyStream))
			recordedBody.withLock { $0 = body }
			return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!, responseData)
		}]
		let options = FetchOptions(url: url.absoluteString, method: "POST", multipartData: [
			MultipartItem(partName: "attributes", data: SerializedData(data: Data("{\"name\":\"file.txt\"}".utf8))),
			MultipartItem(partName: "file", fileStream: InputStream(data: Data("file content".utf8)), fileName: "file.txt")
		], contentType: "multipart/form-data")

		let response = try await client.fetch(options: options)

		XCTAssertEqual(201, response.status)
		XCTAssertEqual(responseData, response.data?.data)
		let body = try XCTUnwrap(String(data: recordedBody.withLock { $0 }, encoding: .utf8))
		let boundary = try XCTUnwrap(body.components(separatedBy: "\r\n").first)
		let expectedBody = "\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n{\"name\":\"file.txt\"}\r\n\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"file.txt\"\r\nContent-Type: application/octet-stream\r\n\r\nfile content\r\n\(boundary)--\r\n"
		XCTAssertEqual(expectedBody, body)
	}

	func testUnsuccessfulResponseThrowsAPIErrorWithRawBody() async {
		URLProtocolMock.requestHandler = [{ [url] _ in
			(HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data("{\"error\":\"invalid_grant\"}".utf8))
		}]
		let options = FetchOptions(url: url.absoluteString, method: "POST", data: SerializedData(data: Data()))

		await XCTAssertThrowsErrorAsync(try await client.fetch(options: options)) { error in
			guard let error = error as? BoxAPIError else {
				XCTFail("Unexpected error: \(error)")
				return
			}
			XCTAssertEqual(400, error.responseInfo.statusCode)
			XCTAssertEqual("{\"error\":\"invalid_grant\"}", error.responseInfo.rawBody)
		}
	}

	func testUnauthorizedResponseIsRetriedWithRefreshedToken() async throws {
		let authorizationHeaders = OSAllocatedUnfairLock(initialState: [String?]())
		URLProtocolMock.requestHandler = [{ [url] request in
			authorizationHeaders.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			return (HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!, nil)
		}, { [url] request in
			authorizationHeaders.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
			return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
		}]
		let options = FetchOptions(url: url.absoluteString, method: "GET", auth: RefreshingAuthenticationMock())

		let response = try await client.fetch(options: options)

		XCTAssertEqual(200, response.status)
		XCTAssertEqual(["Bearer expired", "Bearer refreshed"], authorizationHeaders.withLock { $0 })
	}

	func testDownloadMovesFileToDestination() async throws {
		URLProtocolMock.requestHandler = [{ [url] _ in
			(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("file content".utf8))
		}]
		let destinationURL = tmpDirURL.appendingPathComponent("file.txt")
		let options = FetchOptions(url: url.absoluteString, method: "GET", responseFormat: .binary, downloadDestinationUrl: destinationURL)

		let response = try await client.fetch(options: options)

		XCTAssertEqual(destinationURL, response.downloadDestinationUrl)
		XCTAssertEqual(Data("file content".utf8), try Data(contentsOf: destinationURL))
	}

	func testUnsuccessfulDownloadLeavesDestinationUntouched() async {
		URLProtocolMock.requestHandler = [{ [url] _ in
			(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{\"code\":\"not_found\"}".utf8))
		}]
		let destinationURL = tmpDirURL.appendingPathComponent("file.txt")
		let options = FetchOptions(url: url.absoluteString, method: "GET", responseFormat: .binary, downloadDestinationUrl: destinationURL)

		await XCTAssertThrowsErrorAsync(try await client.fetch(options: options)) { error in
			XCTAssertEqual("not_found", (error as? BoxAPIError)?.responseInfo.code)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
	}

	func testTransportFailureThrowsNetworkError() async {
		URLProtocolMock.requestHandler = [{ _ in
			throw URLError(.notConnectedToInternet)
		}]
		let options = FetchOptions(url: url.absoluteString, method: "GET")

		await XCTAssertThrowsErrorAsync(try await client.fetch(options: options)) { error in
			XCTAssertTrue((error as? BoxNetworkError)?.error is URLError)
		}
	}
}
