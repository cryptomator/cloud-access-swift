//
//  PCloudClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
@testable import CryptomatorCloudAccessCore

class PCloudClientTests: XCTestCase {
	private var sleeps: SleepRecorder!
	private var client: PCloudClient!
	private var tmpDirURL: URL!

	override func setUpWithError() throws {
		sleeps = SleepRecorder()
		client = PCloudClient.mocked(sleeps: sleeps)
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - Requests

	func testCallSendsFormBodyWithAccessToken() async throws {
		let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3), onRequest: { request in
			sentRequest.withLock { $0 = request }
		})]

		_ = try await client.listFolder(3, to: listingURL())

		let request = try XCTUnwrap(sentRequest.withLock { $0 })
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual("https://eapi.pcloud.com/listfolder", request.url?.absoluteString)
		XCTAssertEqual("application/x-www-form-urlencoded", request.value(forHTTPHeaderField: "Content-Type"))
	}

	func testCallGoesToHostOfStoredLogin() async throws {
		let lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer {
			try? FileManager.default.removeItem(at: lockDirectoryURL)
		}
		let buffer = TokenBuffer()
		buffer.store(OAuthToken(accessToken: "STORED", refreshToken: nil, expiresAt: nil, apiHost: "api.pcloud.com"))
		let client = try PCloudClient.mocked(tokenSource: PCloudCredential.makeTokenSource(userID: "1", oauth: .custom(storage: MemoryTokenStorage(buffer: buffer), tokenLockDirectory: lockDirectoryURL)))
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 3), onRequest: requests.record)]

		_ = try await client.listFolder(3, to: listingURL())

		XCTAssertEqual("https://api.pcloud.com/listfolder", requests.requests.first?.url?.absoluteString)
		XCTAssertEqual("STORED", requests.requests.first.map(URLProtocolMock.formParameters)?["access_token"])
	}

	func testCallPercentEncodesParameters() async throws {
		let sentBody = OSAllocatedUnfairLock<String?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 4), onRequest: { request in
			sentBody.withLock { $0 = String(bytes: URLProtocolMock.body(of: request), encoding: .utf8) }
		})]

		_ = try await client.createFolder(name: "a+b&c=d/é ~", parentID: 0)

		let body = try XCTUnwrap(sentBody.withLock { $0 })
		XCTAssertTrue(body.contains("name=a%2Bb%26c%3Dd%2F%C3%A9%20~&"), body)
	}

	func testCommandsSendTheirParameters() async throws {
		for command in PCloudClientTests.commands {
			let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: command.successBody, onRequest: { request in
				sentRequest.withLock { $0 = request }
			})]

			try await command.call(client)

			let request = try XCTUnwrap(sentRequest.withLock { $0 }, command.name)
			XCTAssertEqual("/\(command.name)", request.url?.path, command.name)
			XCTAssertEqual(command.parameters.merging(["access_token": PCloudCredential.stubAccessToken]) { first, _ in first }, URLProtocolMock.formParameters(of: request), command.name)
		}
	}

	func testUploadSendsParametersInQueryAndFileAsBody() async throws {
		let sentRequest = OSAllocatedUnfairLock<(request: URLRequest, body: Data)?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.uploadedFile(id: 42), onRequest: { request in
			sentRequest.withLock { $0 = (request, URLProtocolMock.body(of: request)) }
		})]
		let fileURL = try makeLocalFile()

		let metadata = try await client.upload(fromFile: fileURL, parentID: 3, name: "a+b.txt", progress: nil, onTaskCreation: nil)

		let (request, body) = try XCTUnwrap(sentRequest.withLock { $0 })
		XCTAssertEqual(42, metadata.identifier)
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual("/uploadfile", request.url?.path)
		XCTAssertEqual("application/octet-stream", request.value(forHTTPHeaderField: "Content-Type"))
		let query = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery })
		XCTAssertTrue(query.contains("filename=a%2Bb.txt"), query)
		XCTAssertEqual(["access_token": PCloudCredential.stubAccessToken, "folderid": "3", "filename": "a+b.txt", "nopartial": "1", "iconformat": "id", "timeformat": "timestamp"], URLProtocolMock.parameters(inFormEncoded: query))
		XCTAssertEqual(Data("content".utf8), body)
	}

	func testDownloadSendsOnlyDownloadTagToHostOfLink() async throws {
		let sentRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "content", onRequest: { request in
			sentRequest.withLock { $0 = request }
		})]
		let fileLink = PCloudFileLink(hosts: ["c1.pcloud.com", "c2.pcloud.com"], path: "/dir/a#b?c%d.txt", dwltag: "TAG")
		let stagingURL = tmpDirURL.appendingPathComponent("download.txt")

		try await client.download(fileLink, to: stagingURL, progress: nil, onTaskCreation: nil)

		let request = try XCTUnwrap(sentRequest.withLock { $0 })
		let url = try XCTUnwrap(request.url)
		XCTAssertEqual("GET", request.httpMethod)
		XCTAssertEqual("c1.pcloud.com", url.host)
		XCTAssertEqual(fileLink.path, url.path(percentEncoded: false))
		XCTAssertNil(url.query)
		XCTAssertNil(url.fragment)
		XCTAssertEqual("dwltag=TAG", request.value(forHTTPHeaderField: "Cookie"))
		XCTAssertFalse(url.absoluteString.contains(PCloudCredential.stubAccessToken))
		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: stagingURL))
	}

	// MARK: - Errors

	func testAuthenticationCodeIsUnauthorized() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.result(2094))]

		await XCTAssertThrowsErrorAsync(try await client.listFolder(0, to: listingURL())) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
	}

	func testUnexpectedStatusWithoutResult() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 502, body: "<html>Bad Gateway</html>")]

		await XCTAssertThrowsErrorAsync(try await client.createFolder(name: "folder", parentID: 0)) { error in
			XCTAssertEqual(.unexpectedHTTPStatusCode(code: 502), error as? PCloudError)
		}
	}

	func testSuccessfulStatusWithoutResultIsUnexpectedContent() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: "<html>Login</html>")]

		await XCTAssertThrowsErrorAsync(try await client.createFolder(name: "folder", parentID: 0)) { error in
			XCTAssertEqual(.unexpectedContent, error as? PCloudError)
		}
	}

	func testDoesNotRetryWithoutInternetConnection() async throws {
		URLProtocolMock.requestHandler = [
			{ _ in throw URLError(.notConnectedToInternet) },
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0))
		]

		await XCTAssertThrowsErrorAsync(try await client.listFolder(0, to: listingURL())) { error in
			XCTAssertEqual(.noInternetConnection, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testTransfersWithoutInternetConnectionThrowNoInternetConnection() async throws {
		URLProtocolMock.requestHandler = [
			{ _ in throw URLError(.notConnectedToInternet) },
			{ _ in throw URLError(.notConnectedToInternet) }
		]
		let fileURL = try makeLocalFile()

		await XCTAssertThrowsErrorAsync(try await client.upload(fromFile: fileURL, parentID: 0, name: "a.txt", progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.noInternetConnection, error as? CloudProviderError)
		}
		await XCTAssertThrowsErrorAsync(try await client.download(PCloudMockResponse.link, to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.noInternetConnection, error as? CloudProviderError)
		}
	}

	func testCancelledTasksThrowCancellationError() async throws {
		let client: PCloudClient = client
		let fileURL = try makeLocalFile()
		let downloadURL = tmpDirURL.appendingPathComponent("download.txt")
		let listingURL = listingURL()
		URLProtocolMock.requestHandler = Array(repeating: { _ in throw URLError(.cancelled) }, count: 3)
		let operations: [@Sendable () async throws -> Void] = [
			{ _ = try await client.listFolder(0, to: listingURL) },
			{ _ = try await client.upload(fromFile: fileURL, parentID: 0, name: "a.txt", progress: nil, onTaskCreation: nil) },
			{ try await client.download(PCloudMockResponse.link, to: downloadURL, progress: nil, onTaskCreation: nil) }
		]

		for operation in operations {
			await XCTAssertThrowsErrorAsync(try await operation()) { error in
				XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
			}
		}
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFileLinkWithoutHostThrowsFileLinkNotFound() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"result":0,"hosts":[],"path":"/SECRETPATH/file.txt","dwltag":"SECRETTAG"}"#)]

		await XCTAssertThrowsErrorAsync(try await client.getFileLink(fileID: 5)) { error in
			XCTAssertEqual(.fileLinkNotFound, error as? PCloudError)
		}
	}

	func testFailedDownloadThrowsErrorOfResultAndLeavesNoFile() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 410, body: PCloudMockResponse.result(2009))]
		let stagingURL = tmpDirURL.appendingPathComponent("download.txt")

		await XCTAssertThrowsErrorAsync(try await client.download(PCloudMockResponse.link, to: stagingURL, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.apiError(code: 2009, message: "Error 2009."), error as? PCloudError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
	}

	func testListingErrorsAreJudgedAsInOtherBodies() async throws {
		struct TestCase {
			let name: String
			let handler: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)
			let expectedError: Error
		}
		let cases = [
			TestCase(name: "null message of authentication code", handler: URLProtocolMock.handler(body: #"{"result":2000,"error":null}"#), expectedError: CloudProviderError.unauthorized),
			TestCase(name: "null message", handler: URLProtocolMock.handler(body: #"{"result":2005,"error":null}"#), expectedError: PCloudError.apiError(code: 2005, message: nil)),
			TestCase(name: "message over 4 KiB", handler: URLProtocolMock.handler(body: #"{"result":2005,"error":"\#(String(repeating: "x", count: 4 * 1024))"}"#), expectedError: PCloudError.apiError(code: 2005, message: nil)),
			TestCase(name: "unsuccessful status", handler: URLProtocolMock.handler(statusCode: 410, body: PCloudMockResponse.result(2005)), expectedError: PCloudError.apiError(code: 2005, message: "Error 2005.")),
			// `JSONDecoder` checks the content of a string only where it decodes it.
			TestCase(name: "invalid string in ignored member", handler: URLProtocolMock.handler(body: #"{"result":2000,"other":"\udc00"}"#), expectedError: CloudProviderError.unauthorized)
		]
		for testCase in cases {
			URLProtocolMock.requestHandler = [testCase.handler]

			await XCTAssertThrowsErrorAsync(try await client.listFolder(0, to: listingURL()), testCase.name) { error in
				XCTAssertEqual(String(describing: testCase.expectedError), String(describing: error), testCase.name)
			}
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty, testCase.name)
		}
	}

	func testListingLeavesValuesItDoesNotDecodeToJSONDecoder() async throws {
		let body = PCloudMockResponse.folder(id: 3, contents: [#"{"isfolder":true,"name":"sub","folderid":4,"modified":1,"icon":"\ud800\u0001","x":{"\udc00":01}}"#])
			.replacingOccurrences(of: #"{"result":0,"#, with: #"{"result":0.0000000000000000000000000000000000000,"other":[1-2,--,"\a"],"#)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: body)]

		let listing = try await client.listFolder(3, to: listingURL())

		XCTAssertEqual(3, listing.folder.identifier)
		XCTAssertTrue(listing.hasContents)
	}

	func testListingWithNullContentsHasNoContents() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"result":0,"metadata":{"isfolder":true,"name":"folder","folderid":3,"modified":1792056600,"contents":null}}"#)]

		let listing = try await client.listFolder(3, to: listingURL())

		XCTAssertEqual(3, listing.folder.identifier)
		XCTAssertFalse(listing.hasContents)
	}

	// MARK: - Retries

	func testRetriesTransientFailuresOfReads() async throws {
		// A 2xx response is downloaded to the listing file, so its retry also fails if the file isn't removed in between.
		let transientResponses: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] = [
			URLProtocolMock.handler(body: PCloudMockResponse.result(5000)),
			URLProtocolMock.handler(body: PCloudMockResponse.result(4010)),
			{ _ in throw URLError(.networkConnectionLost) },
			URLProtocolMock.handler(body: "<html>Login</html>"),
			URLProtocolMock.handler(statusCode: 503, body: ""),
			URLProtocolMock.handler(statusCode: 429, body: ""),
			URLProtocolMock.handler(body: String(PCloudMockResponse.folder(id: 0).dropLast())),
			URLProtocolMock.handler(body: #"{"result":0,"error":[\#(Array(repeating: "1", count: 4 * 1024).joined(separator: ","))]}"#),
			URLProtocolMock.handler(body: #"{"result":1-2}"#),
			URLProtocolMock.handler(body: #"{"result":0,"\ud800":0}"#)
		]
		for transientResponse in transientResponses {
			URLProtocolMock.requestHandler = [transientResponse, URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0))]

			let listing = try await client.listFolder(0, to: listingURL())

			XCTAssertEqual(0, listing.folder.identifier)
			XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
		}
	}

	func testRetryReadsLoginAgain() async throws {
		let lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer {
			try? FileManager.default.removeItem(at: lockDirectoryURL)
		}
		let buffer = TokenBuffer()
		buffer.store(OAuthToken(accessToken: "STORED", refreshToken: nil, expiresAt: nil, apiHost: "api.pcloud.com"))
		let client = try PCloudClient.mocked(tokenSource: PCloudCredential.makeTokenSource(userID: "1", oauth: .custom(storage: MemoryTokenStorage(buffer: buffer), tokenLockDirectory: lockDirectoryURL)), sleeps: sleeps)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503, onRequest: { _ in buffer.data = nil }), URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0))]

		await XCTAssertThrowsErrorAsync(try await client.listFolder(0, to: listingURL())) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testRetryWaitsForRetryAfter() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 503, headerFields: ["Retry-After": "2"]), URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0))]

		_ = try await client.listFolder(0, to: listingURL())

		XCTAssertEqual([.seconds(2)], sleeps.durations)
	}

	func testMetadataBodyOverLimitFails() async throws {
		URLProtocolMock.requestHandler = [{ request in
			(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: HTTPClientSupport.maxMetadataBodyLength + 1))
		}]

		await XCTAssertThrowsErrorAsync(try await client.stat(fileID: 1)) { error in
			guard case SplitURLSessionError.responseBodyTooLarge = error else {
				return XCTFail("Unexpected error: \(error)")
			}
		}
	}

	func testListingOverMetadataLimitSucceeds() async throws {
		let body = PCloudMockResponse.folder(id: 0) + String(repeating: " ", count: HTTPClientSupport.maxMetadataBodyLength)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: body)]

		let listing = try await client.listFolder(0, to: listingURL())

		XCTAssertEqual(0, listing.folder.identifier)
	}

	func testDoesNotRetryTooManyLoginAttempts() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.result(4000)),
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0))
		]

		await XCTAssertThrowsErrorAsync(try await client.listFolder(0, to: listingURL())) { error in
			XCTAssertEqual(.apiError(code: 4000, message: "Error 4000."), error as? PCloudError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testDoesNotRetryListingsOfUnexpectedShapeOrSize() async throws {
		let cases: [(body: String, expected: PCloudError)] = [
			(#"{"result":0}"#, .unexpectedContent),
			(PCloudMockResponse.folder(id: 0).replacingOccurrences(of: #""contents":[]"#, with: #""contents":{}"#), .unexpectedContent),
			(PCloudMockResponse.folder(id: 0).replacingOccurrences(of: #""contents""#, with: #""\ud800":0,"contents""#), .unexpectedContent),
			(PCloudMockResponse.folder(id: 0, contents: [#"{"x":\#(String(repeating: "[", count: 64) + String(repeating: "]", count: 64))}"#]), .listingTooLarge),
			(#"{"result":0.\#(String(repeating: "0", count: 4 * 1024))}"#, .listingTooLarge)
		]
		for (body, expected) in cases {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: body), URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0))]

			await XCTAssertThrowsErrorAsync(try await client.listFolder(0, to: listingURL())) { error in
				XCTAssertEqual(expected, error as? PCloudError)
			}
			XCTAssertEqual(1, URLProtocolMock.requestHandler.count, body)
		}
	}

	func testRetriesOnlyReads() async throws {
		for command in PCloudClientTests.commands {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.result(5000)), URLProtocolMock.handler(body: command.successBody)]

			do {
				try await command.call(client)
				XCTAssertTrue(command.isIdempotent, "\(command.name) was retried")
			} catch {
				XCTAssertFalse(command.isIdempotent, "\(command.name) wasn't retried")
				XCTAssertEqual(.apiError(code: 5000, message: "Error 5000."), error as? PCloudError, command.name)
			}
			XCTAssertEqual(command.isIdempotent ? 0 : 1, URLProtocolMock.requestHandler.count, command.name)
		}
	}

	func testDoesNotRetryInCancelledTask() async throws {
		let client: PCloudClient = client
		let listingURL = listingURL()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.result(5000)),
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0))
		]

		await XCTAssertThrowsErrorAsync(try await value(of: cancelledTask {
			try await client.listFolder(0, to: listingURL)
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	// MARK: - Sessions

	func testBackgroundConfiguration() {
		let configuration = PCloudClient.backgroundConfiguration(sessionIdentifier: "PCloudClientTests", sharedContainerIdentifier: "group.test")

		XCTAssertEqual("PCloudClientTests", configuration.identifier)
		XCTAssertEqual("group.test", configuration.sharedContainerIdentifier)
	}

	func testBackgroundClientRunsOnlyTransfersOnBackgroundSession() async throws {
		let registry = BackgroundURLSessionRegistry { _ in URLProtocolMock.configuration(marker: "transfer") }
		let backgroundClient = PCloudClient(tokenSource: PCloudCredential.stubTokenSource, configuration: .background(withIdentifier: "PCloudClientTests"), metadataConfiguration: URLProtocolMock.configuration(marker: "metadata"), registry: registry)
		let markers = OSAllocatedUnfairLock(initialState: [String?]())
		let recordMarker: @Sendable (URLRequest) -> Void = { request in
			markers.withLock { $0.append(request.value(forHTTPHeaderField: "X-Session")) }
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.folder(id: 0), onRequest: recordMarker),
			URLProtocolMock.handler(body: "content", onRequest: recordMarker),
			URLProtocolMock.handler(body: PCloudMockResponse.uploadedFile(id: 42), onRequest: recordMarker)
		]
		let fileURL = try makeLocalFile()

		_ = try await backgroundClient.listFolder(0, to: listingURL())
		try await backgroundClient.download(PCloudMockResponse.link, to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)
		_ = try await backgroundClient.upload(fromFile: fileURL, parentID: 0, name: "a.txt", progress: nil, onTaskCreation: nil)

		XCTAssertEqual(["metadata", "transfer", "transfer"], markers.withLock { $0 })
	}

	// MARK: - Logging

	func testRequestsLeaveNoCredentialsInLog() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: PCloudMockResponse.fileLink()),
			URLProtocolMock.handler(body: PCloudMockResponse.uploadedFile(id: 42)),
			URLProtocolMock.handler(body: "content")
		]
		let fileURL = try makeLocalFile()

		_ = try await client.getFileLink(fileID: 5)
		_ = try await client.upload(fromFile: fileURL, parentID: 0, name: "a.txt", progress: nil, onTaskCreation: nil)
		try await client.download(PCloudMockResponse.link, to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)

		let log = logCapture.joinedMessages
		XCTAssertTrue(log.contains("--> GET https://c1.pcloud.com/<redacted>"), log)
		for secret in [PCloudCredential.stubAccessToken, PCloudMockResponse.link.path, PCloudMockResponse.link.dwltag] {
			XCTAssertFalse(log.contains(secret), "\(secret) in \(log)")
		}
	}

	func testFailedTransfersLeaveNoCredentialsInLogOrError() async throws {
		let logCapture = LogCapture.start()
		defer {
			logCapture.stop()
		}
		let failWithURL: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) = { request in
			let url = try XCTUnwrap(request.url)
			throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])
		}
		URLProtocolMock.requestHandler = [failWithURL, failWithURL]
		let fileURL = try makeLocalFile()
		var errors = [Error]()

		do {
			_ = try await client.upload(fromFile: fileURL, parentID: 0, name: "a.txt", progress: nil, onTaskCreation: nil)
		} catch {
			errors.append(error)
		}
		do {
			try await client.download(PCloudMockResponse.link, to: tmpDirURL.appendingPathComponent("download.txt"), progress: nil, onTaskCreation: nil)
		} catch {
			errors.append(error)
		}

		XCTAssertEqual([.timedOut, .timedOut], errors.map { ($0 as? URLError)?.code })
		for text in [logCapture.joinedMessages] + errors.map({ String(describing: $0) }) {
			for secret in [PCloudCredential.stubAccessToken, PCloudMockResponse.link.path, PCloudMockResponse.link.dwltag] {
				XCTAssertFalse(text.contains(secret), "\(secret) in \(text)")
			}
		}
	}

	// MARK: - Helpers

	private struct Command: Sendable {
		let name: String
		let parameters: [String: String]
		let isIdempotent: Bool
		let successBody: String
		let call: @Sendable (PCloudClient) async throws -> Void
	}

	private static let formatParameters = ["iconformat": "id", "timeformat": "timestamp"]

	/// Every API call of the client that sends a form body, with the parameters besides `access_token` that pcloud-sdk-swift 3.2 sent for it.
	private static let commands = [
		Command(name: "listfolder", parameters: ["folderid": "3", "recursive": "0"].merging(formatParameters) { $1 }, isIdempotent: true, successBody: PCloudMockResponse.folder(id: 3), call: { client in
			let listingURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
			defer {
				try? FileManager.default.removeItem(at: listingURL)
			}
			_ = try await client.listFolder(3, to: listingURL)
		}),
		Command(name: "stat", parameters: ["fileid": "5"].merging(formatParameters) { $1 }, isIdempotent: true, successBody: PCloudMockResponse.file(id: 5), call: { _ = try await $0.stat(fileID: 5) }),
		Command(name: "getfilelink", parameters: ["fileid": "5", "timeformat": "timestamp"], isIdempotent: true, successBody: PCloudMockResponse.fileLink(), call: { _ = try await $0.getFileLink(fileID: 5) }),
		Command(name: "userinfo", parameters: [:], isIdempotent: true, successBody: #"{"result":0,"email":"user@example.com"}"#, call: { _ = try await $0.userInfoEmail() }),
		Command(name: "createfolder", parameters: ["name": "folder", "folderid": "3"].merging(formatParameters) { $1 }, isIdempotent: false, successBody: PCloudMockResponse.folder(id: 4), call: { _ = try await $0.createFolder(name: "folder", parentID: 3) }),
		Command(name: "renamefolder", parameters: ["folderid": "4", "tofolderid": "3", "toname": "renamed"].merging(formatParameters) { $1 }, isIdempotent: false, successBody: PCloudMockResponse.folder(id: 4), call: { _ = try await $0.renameFolder(4, toParent: 3, name: "renamed") }),
		Command(name: "deletefolderrecursive", parameters: ["folderid": "4"], isIdempotent: false, successBody: #"{"result":0,"deletedfiles":1,"deletedfolders":1}"#, call: { try await $0.deleteFolderRecursive(4) }),
		Command(name: "renamefile", parameters: ["fileid": "5", "tofolderid": "3", "toname": "renamed.txt"].merging(formatParameters) { $1 }, isIdempotent: false, successBody: PCloudMockResponse.file(id: 5), call: { _ = try await $0.renameFile(5, toParent: 3, name: "renamed.txt") }),
		Command(name: "deletefile", parameters: ["fileid": "5"].merging(formatParameters) { $1 }, isIdempotent: false, successBody: PCloudMockResponse.file(id: 5), call: { try await $0.deleteFile(5) })
	]

	private func listingURL() -> URL {
		return tmpDirURL.appendingPathComponent(UUID().uuidString)
	}

	private func makeLocalFile() throws -> URL {
		let localURL = tmpDirURL.appendingPathComponent("local.txt")
		try Data("content".utf8).write(to: localURL)
		return localURL
	}
}

extension PCloudCredential {
	static let stubAccessToken = "TOKEN123"
	static let stubTokenSource = StaticOAuthTokenSource(token: stubAccessToken, apiHost: "eapi.pcloud.com")
}

extension PCloudClient {
	static func mocked(tokenSource: any PCloudTokenSource = PCloudCredential.stubTokenSource, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks(), sleeps: SleepRecorder = SleepRecorder()) -> PCloudClient {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		return PCloudClient(tokenSource: tokenSource, configuration: configuration, metadataConfiguration: nil, hooks: hooks, sleep: { sleeps.sleep(for: $0) })
	}
}

enum PCloudMockResponse {
	static let link = PCloudFileLink(hosts: ["c1.pcloud.com"], path: "/SECRETPATH/file.txt", dwltag: "SECRETTAG")

	static func result(_ code: Int) -> String {
		return #"{"result":\#(code),"error":"Error \#(code)."}"#
	}

	static func folder(id: UInt64, name: String = "folder", contents: [String] = []) -> String {
		return #"{"result":0,"metadata":{"isfolder":true,"name":"\#(name)","folderid":\#(id),"modified":1792056600,"contents":[\#(contents.joined(separator: ","))]}}"#
	}

	static func fileEntry(id: UInt64, name: String, size: Int = 7) -> String {
		return #"{"isfolder":false,"name":"\#(name)","fileid":\#(id),"modified":1792056600,"size":\#(size)}"#
	}

	static func folderEntry(id: UInt64, name: String) -> String {
		return #"{"isfolder":true,"name":"\#(name)","folderid":\#(id),"modified":1792056600}"#
	}

	static func file(id: UInt64, name: String = "file.txt", size: Int = 7) -> String {
		return #"{"result":0,"metadata":\#(fileEntry(id: id, name: name, size: size))}"#
	}

	static func uploadedFile(id: UInt64, name: String = "file.txt", size: Int = 7) -> String {
		return #"{"result":0,"fileids":[\#(id)],"metadata":[\#(fileEntry(id: id, name: name, size: size))]}"#
	}

	static func fileLink() -> String {
		return #"{"result":0,"hosts":["\#(link.hosts[0])"],"path":"\#(link.path)","dwltag":"\#(link.dwltag)","expires":"Mon, 19 Oct 2026 22:00:00 +0000"}"#
	}
}
