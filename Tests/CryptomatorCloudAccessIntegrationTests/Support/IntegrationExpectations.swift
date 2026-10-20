//
//  IntegrationExpectations.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Foundation
import os
import Testing

/**
 Expects the operation to throw the given error.

 A transient error is rethrown instead of recorded, so that the test runner retries the test.
 */
func expectCloudProviderError(_ expected: CloudProviderError, sourceLocation: SourceLocation = #_sourceLocation, _ operation: () async throws -> some Any) async throws {
	do {
		_ = try await operation()
		Issue.record("Expected \(expected), but nothing was thrown", sourceLocation: sourceLocation)
	} catch {
		if isTransientIntegrationError(error) {
			throw error
		}
		#expect((error as? CloudProviderError) == expected, "Expected \(expected), but \(error) was thrown", sourceLocation: sourceLocation)
	}
}

/**
 Checks the condition until it holds, to wait out the visibility lag of a remote provider. The local file system is checked once.

 Other providers are polled with exponential backoff. An eventually consistent provider gets up to 60 seconds, after which `IntegrationTestError.consistencyTimeout` is thrown, because there the lag is the expected flake. Any other provider gets up to 20 seconds, after which the result is `false`, so that a regression fails the test instead of being retried.
 */
func eventually(on kind: IntegrationProvider, _ condition: () async throws -> Bool) async throws -> Bool {
	guard kind.isRemote else {
		return try await condition()
	}
	let budget: Duration = kind.isEventuallyConsistent ? .seconds(60) : .seconds(20)
	let clock = ContinuousClock()
	let deadline = clock.now + budget
	var delay: Duration = .milliseconds(500)
	while true {
		if try await condition() {
			return true
		}
		guard clock.now < deadline else {
			if kind.isEventuallyConsistent {
				throw IntegrationTestError.consistencyTimeout
			}
			return false
		}
		try await Task.sleep(for: min(delay, deadline - clock.now))
		delay = min(delay * 2, .seconds(8))
	}
}

/// Waits until the item that was just created is visible through the given provider, so that the next step doesn't fail on the visibility lag.
func waitUntilVisible(_ cloudPath: CloudPath, through provider: CloudProvider, on kind: IntegrationProvider) async throws {
	guard try await eventually(on: kind, { try await provider.checkForItemExistence(at: cloudPath) }) else {
		throw IntegrationTestError.itemNotVisible(cloudPath)
	}
}

// MARK: - Tasks

/// How long a test waits for a step to happen, generous because a loaded CI machine can stall for over half a minute.
let testWaitTimeout: Duration = .seconds(60)

struct UnfinishedTaskError: Error, CustomStringConvertible {
	let timeout: Duration

	var description: String {
		return "Task did not finish within \(timeout)"
	}
}

func taskSleep(for duration: Duration) async throws {
	try await Task.sleep(for: duration)
}

/// Starts the operation in a task that is already cancelled when the operation begins.
func cancelledTask<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) -> Task<Value, Error> {
	return Task {
		withUnsafeCurrentTask { $0?.cancel() }
		return try await operation()
	}
}

/**
 Waits for the value of a task, but at most for the timeout, after which `UnfinishedTaskError` is thrown and the task is left running.

 A task group can't serve as the timeout, because it only returns once all of its child tasks returned, and a running request doesn't respond to cancellation.

 The timeout runs out when `sleep` returns, and never if it throws.
 */
func value<Value: Sendable>(of task: Task<Value, Error>, timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void = taskSleep(for:)) async throws -> Value {
	let lockedContinuation = OSAllocatedUnfairLock<CheckedContinuation<Value, Error>?>(initialState: nil)
	let lockedTimer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
	let resume: @Sendable (Result<Value, Error>) -> Void = { result in
		lockedContinuation.withLock { continuation in
			defer { continuation = nil }
			return continuation
		}?.resume(with: result)
		lockedTimer.withLock { $0 }?.cancel()
	}
	return try await withCheckedThrowingContinuation { continuation in
		lockedContinuation.withLock { $0 = continuation }
		lockedTimer.withLock { timer in
			timer = Task {
				guard await (try? sleep(timeout)) != nil else {
					return
				}
				resume(.failure(UnfinishedTaskError(timeout: timeout)))
			}
		}
		Task {
			let result = await task.result
			resume(result)
		}
	}
}

// MARK: - CloudItemMetadata

extension CloudItemMetadata: @retroactive Comparable, @retroactive Equatable {
	public static func < (lhs: CloudItemMetadata, rhs: CloudItemMetadata) -> Bool {
		return lhs.name < rhs.name
	}

	public static func == (lhs: CloudItemMetadata, rhs: CloudItemMetadata) -> Bool {
		return lhs.name == rhs.name && lhs.cloudPath == rhs.cloudPath && lhs.itemType == rhs.itemType
	}
}
