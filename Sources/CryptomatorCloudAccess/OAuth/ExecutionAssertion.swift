//
//  ExecutionAssertion.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

/**
 Runs an operation while the process holds an expiring activity assertion, so that iOS doesn't suspend it in the middle, e.g., while it holds a file lock.

 `performExpiringActivity(withReason:using:)` calls its block once with `false` when it took an assertion, and with `true` when it couldn't take one, or later when the granted time runs out.
 */
final class ProcessExecutionAssertion: Sendable {
	typealias Activity = @Sendable (_ reason: String, _ block: @escaping @Sendable (_ expired: Bool) -> Void) -> Void

	private enum Phase {
		case waiting
		case running
		case finished
	}

	private enum Action {
		case start
		case reportUnavailable
		case expire
		case none
	}

	private let performActivity: Activity

	init(performActivity: @escaping Activity = { reason, block in ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: block) }) {
		self.performActivity = performActivity
	}

	/**
	 Runs the operation once the process holds an assertion.

	 The operation's result is returned also if the assertion expires while it runs.

	 - Parameter operation: Gets a closure that tells whether the assertion has expired, so that it can stop before its next protected step.
	 - Parameter onExpiration: Runs once when the assertion expires while the operation runs, e.g., to release a lock right away.
	 - Throws: `OAuthTokenStoreError.executionTimeUnavailable` without running the operation if the process gets no assertion, and otherwise what the operation throws.
	 */
	func perform<T: Sendable>(reason: String, operation: @escaping @Sendable (_ isExpired: @escaping @Sendable () -> Bool) async throws -> T, onExpiration: @escaping @Sendable () -> Void) async throws -> T {
		let state = OSAllocatedUnfairLock(initialState: (phase: Phase.waiting, isExpired: false))
		let isExpired: @Sendable () -> Bool = {
			state.withLock { $0.isExpired }
		}
		return try await withSDKContinuation { resumer in
			performActivity(reason) { expired in
				let action = state.withLock { state -> Action in
					switch (state.phase, expired) {
					case (.waiting, false):
						state.phase = .running
						return .start
					case (.waiting, true):
						state.phase = .finished
						return .reportUnavailable
					case (.running, true) where !state.isExpired:
						state.isExpired = true
						return .expire
					default:
						return .none
					}
				}
				switch action {
				case .start:
					// The assertion lasts only while the block runs, so the block waits for the operation.
					let semaphore = DispatchSemaphore(value: 0)
					Task {
						do {
							let value = try await operation(isExpired)
							resumer.resume(returning: value)
						} catch {
							resumer.resume(throwing: error)
						}
						state.withLock { $0.phase = .finished }
						semaphore.signal()
					}
					semaphore.wait()
				case .reportUnavailable:
					resumer.resume(throwing: OAuthTokenStoreError.executionTimeUnavailable)
				case .expire:
					onExpiration()
				case .none:
					break
				}
			}
		}
	}
}
