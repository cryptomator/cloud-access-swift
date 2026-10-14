//
//  SDKContinuation.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

/// Resumes the suspended SDK call at most once. Any further resume is ignored and logged.
struct Resumer<T>: Sendable {
	private let continuation: OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>

	fileprivate init(_ continuation: CheckedContinuation<T, any Error>) {
		self.continuation = OSAllocatedUnfairLock(initialState: continuation)
	}

	func resume(returning value: sending T) {
		takeContinuation()?.resume(returning: value)
	}

	func resume(throwing error: any Error) {
		takeContinuation()?.resume(throwing: error)
	}

	func resume(with result: sending Result<T, some Error>) {
		takeContinuation()?.resume(with: result)
	}

	private func takeContinuation() -> CheckedContinuation<T, any Error>? {
		let continuation = continuation.withLock { continuation in
			defer { continuation = nil }
			return continuation
		}
		if continuation == nil {
			CloudAccessDDLogDebug("Resumer<\(T.self)>: ignored a resume after the call was already resumed")
		}
		return continuation
	}
}

extension Resumer where T == Void {
	func resume() {
		resume(returning: ())
	}
}

/**
 Suspends until the completion handler of an SDK call resumes the given `Resumer`.

 Task cancellation is not forwarded to the SDK, so the call returns only after the SDK called back.

 - Parameter start: Issues the SDK call in the caller's isolation and hands the `Resumer` to its completion handler. If the caller is isolated to an actor, a completion handler written inside `start` inherits that isolation and traps when the SDK calls it on another thread, unless it is marked `@Sendable`.
 */
func withSDKContinuation<T>(_ start: (Resumer<T>) -> Void) async throws -> sending T {
	return try await withCheckedThrowingContinuation { continuation in
		start(Resumer(continuation))
	}
}

/**
 Variant of `withSDKContinuation(_:)` for SDKs without a documented thread-safety guarantee.

 - Parameter start: Issues the SDK call on the main actor and hands the `Resumer` to its completion handler. It is not isolated to the main actor itself, so that the SDK can call a completion handler written inside `start` on any thread.
 */
@MainActor
func withMainActorSDKContinuation<T>(_ start: @Sendable (Resumer<T>) -> Void) async throws -> sending T {
	return try await withCheckedThrowingContinuation { continuation in
		start(Resumer(continuation))
	}
}
