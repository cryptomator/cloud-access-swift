//
//  WebAuthenticationSessionTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 22.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
@testable import CryptomatorCloudAccess

@MainActor
class WebAuthenticationSessionTests: XCTestCase {
	private static let callbackURL = URL(string: "scheme://callback?code=CODE")!

	func testReturnsCallbackURL() async throws {
		let session = WebLoginSessionMock()
		let login = Task {
			try await WebAuthenticationSessionTests.run(session)
		}
		await fulfillment(of: [session.started], timeout: testWaitTimeout)

		session.complete(callbackURL: WebAuthenticationSessionTests.callbackURL, error: nil)

		let url = try await value(of: login)
		XCTAssertEqual(WebAuthenticationSessionTests.callbackURL, url)
	}

	func testConvertsCompletionError() async throws {
		let session = WebLoginSessionMock()
		let login = Task {
			try await WebAuthenticationSessionTests.run(session)
		}
		await fulfillment(of: [session.started], timeout: testWaitTimeout)

		session.complete(callbackURL: nil, error: CocoaError(.featureUnsupported))

		await XCTAssertThrowsErrorAsync(try await value(of: login)) { error in
			XCTAssertEqual(.featureUnsupported, (error as? ConvertedError)?.error?.code)
		}
	}

	func testThrowsConvertedErrorIfSessionDidNotStart() async throws {
		let session = WebLoginSessionMock(starts: false)

		await XCTAssertThrowsErrorAsync(try await WebAuthenticationSessionTests.run(session)) { error in
			XCTAssertNotNil(error as? ConvertedError, "Unexpected error: \(error)")
			XCTAssertNil((error as? ConvertedError)?.error)
		}
	}

	func testCancellationCancelsSession() async throws {
		let session = WebLoginSessionMock()
		let login = Task {
			try await WebAuthenticationSessionTests.run(session)
		}
		await fulfillment(of: [session.started], timeout: testWaitTimeout)

		login.cancel()

		await XCTAssertThrowsErrorAsync(try await value(of: login)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		await fulfillment(of: [session.cancelled], timeout: testWaitTimeout)
	}

	func testCompletionAfterCancellationIsIgnored() async throws {
		let session = WebLoginSessionMock()
		let login = Task {
			try await WebAuthenticationSessionTests.run(session)
		}
		await fulfillment(of: [session.started], timeout: testWaitTimeout)
		login.cancel()
		await fulfillment(of: [session.cancelled], timeout: testWaitTimeout)

		session.complete(callbackURL: nil, error: CocoaError(.userCancelled))
		session.complete(callbackURL: WebAuthenticationSessionTests.callbackURL, error: nil)

		await XCTAssertThrowsErrorAsync(try await value(of: login)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
	}

	func testCancelledTaskStartsNoSession() async throws {
		let session = WebLoginSessionMock()
		session.started.isInverted = true

		await XCTAssertThrowsErrorAsync(try await value(of: cancelledTask {
			try await WebAuthenticationSessionTests.run(session)
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		await fulfillment(of: [session.started], timeout: 0.1)
	}

	private static func run(_ session: WebLoginSessionMock) async throws -> URL {
		return try await runWebAuthenticationSession(logPrefix: "WebAuthenticationSessionTests", convertError: { ConvertedError(error: $0 as? CocoaError) }, makeSession: { completion in
			session.completion = completion
			return session
		})
	}
}

private struct ConvertedError: Error {
	let error: CocoaError?
}

@MainActor
private final class WebLoginSessionMock: WebLoginSession {
	let started = XCTestExpectation(description: "started")
	let cancelled = XCTestExpectation(description: "cancelled")
	var completion: (@Sendable (URL?, Error?) -> Void)?
	private let starts: Bool

	init(starts: Bool = true) {
		self.starts = starts
	}

	func start() -> Bool {
		started.fulfill()
		return starts
	}

	func cancel() {
		cancelled.fulfill()
	}

	func complete(callbackURL: URL?, error: Error?) {
		completion?(callbackURL, error)
	}
}
