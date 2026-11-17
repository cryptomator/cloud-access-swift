//
//  WebAuthenticationSessionTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 22.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccess
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	@MainActor
	struct WebAuthenticationSessionTests {
		private static let callbackURL = URL(string: "scheme://callback?code=CODE")!

		@Test
		func returnsCallbackURL() async throws {
			let session = WebLoginSessionMock()
			let login = Task {
				try await WebAuthenticationSessionTests.run(session)
			}
			await session.started.wait()

			session.complete(callbackURL: WebAuthenticationSessionTests.callbackURL, error: nil)

			let url = try await cancellingValue(of: login)
			#expect(WebAuthenticationSessionTests.callbackURL == url)
		}

		@Test
		func convertsCompletionError() async throws {
			let session = WebLoginSessionMock()
			let login = Task {
				try await WebAuthenticationSessionTests.run(session)
			}
			await session.started.wait()

			session.complete(callbackURL: nil, error: CocoaError(.featureUnsupported))

			let error = try await #require(throws: (any Error).self) { try await cancellingValue(of: login) }
			#expect((error as? ConvertedError)?.error?.code == .featureUnsupported)
		}

		@Test
		func throwsConvertedErrorIfSessionDidNotStart() async throws {
			let session = WebLoginSessionMock(starts: false)

			let error = try await #require(throws: (any Error).self) { try await WebAuthenticationSessionTests.run(session) }
			#expect((error as? ConvertedError) != nil, "Unexpected error: \(error)")
			#expect((error as? ConvertedError)?.error == nil)
		}

		@Test
		func cancellationCancelsSession() async throws {
			let session = WebLoginSessionMock()
			let login = Task {
				try await WebAuthenticationSessionTests.run(session)
			}
			await session.started.wait()

			login.cancel()

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: login) }
			await session.cancelled.wait()
		}

		@Test
		func completionAfterCancellationIsIgnored() async throws {
			let session = WebLoginSessionMock()
			let login = Task {
				try await WebAuthenticationSessionTests.run(session)
			}
			await session.started.wait()
			login.cancel()
			await session.cancelled.wait()

			session.complete(callbackURL: nil, error: CocoaError(.userCancelled))
			session.complete(callbackURL: WebAuthenticationSessionTests.callbackURL, error: nil)

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: login) }
		}

		@Test
		func cancelledTaskStartsNoSession() async throws {
			let session = WebLoginSessionMock()

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: cancelledTask {
					try await WebAuthenticationSessionTests.run(session)
				})
			}
			await session.started.expectNoFulfillment(within: .milliseconds(100))
		}

		private static func run(_ session: WebLoginSessionMock) async throws -> URL {
			return try await runWebAuthenticationSession(logPrefix: "WebAuthenticationSessionTests", convertError: { ConvertedError(error: $0 as? CocoaError) }, makeSession: { completion in
				session.completion = completion
				return session
			})
		}
	}
}

private struct ConvertedError: Error {
	let error: CocoaError?
}

@MainActor
private final class WebLoginSessionMock: WebLoginSession {
	let started = TestSignal("started")
	let cancelled = TestSignal("cancelled")
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
