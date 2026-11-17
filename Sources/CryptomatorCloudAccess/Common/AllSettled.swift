//
//  AllSettled.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Runs the operation for all elements concurrently, at most `limit` at a time. It waits until every started operation either succeeded or failed.

 Once the task is cancelled, no further operation starts.

 - Parameter isSkipped: Whether an operation's error leaves its element out without counting as a failure, so a call whose operations were all skipped returns no values instead of throwing.
 - Returns: The values of the operations that succeeded, in the order of their elements.
 - Throws: `CancellationError` if the task or one of the operations was cancelled. Otherwise, the error of the last failed element if no operation succeeded.
 */
func allSettled<Element: Sendable, Value: Sendable>(_ elements: [Element], limit: Int, skipping isSkipped: (Error) -> Bool = { _ in false }, _ operation: @escaping @Sendable (Element) async throws -> Value) async throws -> [Value] {
	precondition(limit > 0)
	let results = try await mapConcurrently(elements, limit: limit) { element -> Result<Value, Error> in
		do {
			return try await .success(operation(element))
		} catch {
			return .failure(error)
		}
	}
	try Task.checkCancellation()
	var values = [Value]()
	var lastError: Error?
	for result in results {
		switch result {
		case let .success(value):
			values.append(value)
		case let .failure(error):
			if error is CancellationError {
				throw error
			}
			if !isSkipped(error) {
				lastError = error
			}
		}
	}
	if values.isEmpty, let lastError {
		throw lastError
	}
	return values
}
