//
//  CancellationError.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Checks for `CancellationError` and for `URLError.cancelled`, which `URLSession` reports for a cancelled task or an invalidated session.
/// Errors outside `NSURLErrorDomain` are unwrapped recursively through `NSUnderlyingErrorKey`, because SDKs wrap the errors of their requests.
func isCancellationError(_ error: Error) -> Bool {
	if error is CancellationError {
		return true
	}
	if let urlError = error as? URLError {
		return urlError.code == .cancelled
	}
	let nsError = error as NSError
	if nsError.domain == NSURLErrorDomain {
		return nsError.code == NSURLErrorCancelled
	}
	if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
		return isCancellationError(underlyingError)
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
