//
//  BackgroundURLSessionRegistryTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	/// The registry creates `.default` sessions for the fake background identifiers, because the hostless test bundle can't create background sessions.
	struct BackgroundURLSessionRegistryTests {
		private let url = URL(string: "https://example.com/file")!
		private let sessionCreationCount = OSAllocatedUnfairLock(initialState: 0)
		private let registry: BackgroundURLSessionRegistry

		init() {
			URLProtocolMock.requestHandler = []
			self.registry = BackgroundURLSessionRegistry { [sessionCreationCount] _ in
				sessionCreationCount.withLock { $0 += 1 }
				let configuration = URLSessionConfiguration.default
				configuration.protocolClasses = [URLProtocolMock.self]
				return configuration
			}
		}

		@Test
		func returnsSameSessionForSameIdentifier() {
			let session = registry.session(for: .background(withIdentifier: "test"))
			#expect(session === registry.session(for: .background(withIdentifier: "test")))
			#expect(sessionCreationCount.withLock { $0 } == 1)
		}

		@Test
		func returnsDifferentSessionsForDifferentIdentifiers() {
			let session = registry.session(for: .background(withIdentifier: "test"))
			#expect(!(session === registry.session(for: .background(withIdentifier: "other"))))
		}

		@Test
		func releasedOwnerLeavesRunningRequestAlive() async throws {
			let requestStarted = TestSignal("request started")
			let requestGate = DispatchSemaphore(value: 0)
			URLProtocolMock.requestHandler = [{ [url] _ in
				requestStarted.fulfill()
				_ = requestGate.wait(timeout: testWaitDeadline())
				return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("content".utf8))
			}]
			var owner: SplitURLSession? = SplitURLSession(configuration: .background(withIdentifier: "test"), registry: registry)
			weak let releasedOwner = owner
			let session = registry.session(for: .background(withIdentifier: "test"))
			let request = Task { [url] in
				try await session.data(from: url)
			}
			await requestStarted.wait()

			owner = nil
			#expect(releasedOwner == nil)
			requestGate.signal()
			let (data, response) = try await cancellingValue(of: request)

			#expect((response as? HTTPURLResponse)?.statusCode == 200)
			#expect(Data("content".utf8) == data)
		}

		@Test
		func ownersOfSameIdentifierShareSession() async throws {
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

			#expect(try HTTPClientSupport.httpResponse(of: outcome).statusCode == 200)
			#expect(try HTTPClientSupport.httpResponse(of: otherOutcome).statusCode == 200)
			#expect(sessionCreationCount.withLock { $0 } == 1)
		}
	}
}
