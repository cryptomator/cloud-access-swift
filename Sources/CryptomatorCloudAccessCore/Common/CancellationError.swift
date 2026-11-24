//
//  CancellationError.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Checks for `CancellationError` and for `URLError.cancelled`, which `URLSession` reports for a cancelled task or an invalidated session. An `NSError` in `NSURLErrorDomain` casts to `URLError`.
/// The first error of the underlying error chain that is either of them decides.
func isCancellationError(_ error: Error) -> Bool {
	for chainedError in underlyingErrorChain(of: error) {
		if chainedError is CancellationError {
			return true
		}
		if let urlError = chainedError as? URLError {
			return urlError.code == .cancelled
		}
	}
	return false
}

/**
 Awaits an operation in a task that doesn't inherit the cancellation of the current task.

 The operation runs to its end even if the current task is cancelled meanwhile, and the call returns only after the operation finished. Errors that the operation throws, including a `CancellationError`, propagate unchanged.

 - Parameter operation: The work that must not stop halfway, e.g., the remote changes of a mutation after its commit point.
 */
func withoutCancellation<T: Sendable>(_ operation: @escaping @concurrent @Sendable () async throws -> T) async throws -> T {
	return try await Task { try await operation() }.value
}
