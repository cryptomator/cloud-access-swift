//
//  AsyncTestSupport.swift
//  CryptomatorCloudAccessTestSupport
//
//  Created by Tobias Hagemann on 21.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

/// How long a test waits for a step that it expects to happen. The CI simulator stalls for over half a minute at times, so a shorter wait fails tests that aren't broken.
package let testWaitTimeout: Duration = .seconds(60)

package struct UnfinishedTaskError: Error, CustomStringConvertible {
	package let timeout: Duration

	package init(timeout: Duration) {
		self.timeout = timeout
	}

	package var description: String {
		return "Task did not finish within \(timeout)"
	}
}

package func taskSleep(for duration: Duration) async throws {
	try await Task.sleep(for: duration)
}

/// Starts the operation in a task that is already cancelled when the operation begins.
package func cancelledTask<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) -> Task<Value, Error> {
	return Task {
		withUnsafeCurrentTask { $0?.cancel() }
		return try await operation()
	}
}

/**
 Waits for the value of a task, but at most for the timeout, after which `UnfinishedTaskError` is thrown and the task is left running.

 The timeout runs out when `sleep` returns, and never if it throws.
 */
package func value<Value: Sendable>(of task: Task<Value, Error>, timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void = taskSleep(for:)) async throws -> Value {
	guard let result = await result(of: task, timeout: timeout, sleep: sleep) else {
		throw UnfinishedTaskError(timeout: timeout)
	}
	return try result.get()
}

/**
 Returns the result of a task, or `nil` once the timeout runs out first, leaving the task running. The timeout runs out when `sleep` returns, and never if it throws.

 A task group can't serve as the timeout, because it only returns once all of its child tasks returned, and a child that awaits the task's result doesn't end when the group cancels it.
 */
package func result<Value: Sendable>(of task: Task<Value, Error>, timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) async -> Result<Value, Error>? {
	let lockedContinuation = OSAllocatedUnfairLock<CheckedContinuation<Result<Value, Error>?, Never>?>(initialState: nil)
	let lockedTimer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
	let resume: @Sendable (Result<Value, Error>?) -> Void = { result in
		lockedContinuation.withLock { continuation in
			defer { continuation = nil }
			return continuation
		}?.resume(returning: result)
		lockedTimer.withLock { $0 }?.cancel()
	}
	return await withCheckedContinuation { continuation in
		lockedContinuation.withLock { $0 = continuation }
		lockedTimer.withLock { timer in
			timer = Task {
				guard await (try? sleep(timeout)) != nil else {
					return
				}
				resume(nil)
			}
		}
		Task {
			let result = await task.result
			resume(result)
		}
	}
}
