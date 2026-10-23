//
//  BackgroundURLSessionRegistryTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// The registry creates `.default` sessions for the fake background identifiers, because the hostless test bundle can't create background sessions.
class BackgroundURLSessionRegistryTests: XCTestCase {
	private let url = URL(string: "https://example.com/file")!
	private let sessionCreationCount = OSAllocatedUnfairLock(initialState: 0)
	private var registry: BackgroundURLSessionRegistry!

	override func setUp() {
		registry = BackgroundURLSessionRegistry { [sessionCreationCount] _ in
			sessionCreationCount.withLock { $0 += 1 }
			let configuration = URLSessionConfiguration.default
			configuration.protocolClasses = [URLProtocolMock.self]
			return configuration
		}
	}

	override func tearDown() {
		URLProtocolMock.requestHandler = []
	}

	func testReturnsSameSessionForSameIdentifier() {
		let session = registry.session(for: .background(withIdentifier: "test"))
		XCTAssertTrue(session === registry.session(for: .background(withIdentifier: "test")))
		XCTAssertEqual(1, sessionCreationCount.withLock { $0 })
	}

	func testReturnsDifferentSessionsForDifferentIdentifiers() {
		let session = registry.session(for: .background(withIdentifier: "test"))
		XCTAssertFalse(session === registry.session(for: .background(withIdentifier: "other")))
	}

	func testReleasedOwnerLeavesRunningRequestAlive() async throws {
		let requestStarted = XCTestExpectation(description: "request started")
		let requestGate = DispatchSemaphore(value: 0)
		URLProtocolMock.requestHandler = [{ [url] _ in
			requestStarted.fulfill()
			_ = requestGate.wait(timeout: .now() + testWaitTimeout)
			return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("content".utf8))
		}]
		var owner: SplitURLSession? = SplitURLSession(configuration: .background(withIdentifier: "test"), registry: registry)
		weak let releasedOwner = owner
		let session = registry.session(for: .background(withIdentifier: "test"))
		let request = Task { [url] in
			try await session.data(from: url)
		}
		await fulfillment(of: [requestStarted], timeout: testWaitTimeout)

		owner = nil
		XCTAssertNil(releasedOwner)
		requestGate.signal()
		let (data, response) = try await value(of: request)

		XCTAssertEqual(200, (response as? HTTPURLResponse)?.statusCode)
		XCTAssertEqual(Data("content".utf8), data)
	}

	func testOwnersOfSameIdentifierShareSession() async throws {
		URLProtocolMock.requestHandler = Array(repeating: { [url] _ in
			(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
		}, count: 2)
		let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try Data("content".utf8).write(to: fileURL)
		defer {
			try? FileManager.default.removeItem(at: fileURL)
		}
		let owner = SplitURLSession(configuration: .background(withIdentifier: "test"), registry: registry)
		let otherOwner = SplitURLSession(configuration: .background(withIdentifier: "test"), registry: registry)

		let outcome = try await owner.upload(URLRequest(url: url), fromFile: fileURL, bodyLimit: nil, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
		let otherOutcome = try await otherOwner.upload(URLRequest(url: url), fromFile: fileURL, bodyLimit: nil, bodyLogging: .logged, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)

		XCTAssertEqual(200, try HTTPClientSupport.httpResponse(of: outcome).statusCode)
		XCTAssertEqual(200, try HTTPClientSupport.httpResponse(of: otherOutcome).statusCode)
		XCTAssertEqual(1, sessionCreationCount.withLock { $0 })
	}
}
