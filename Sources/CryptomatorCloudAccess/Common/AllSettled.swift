//
//  AllSettled.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Runs the operation for all elements concurrently and waits until every operation either succeeded or failed.

 - Parameter isSkipped: Whether an operation's error leaves its element out without counting as a failure, so a call whose operations were all skipped returns no values instead of throwing.
 - Returns: The values of the operations that succeeded, in the order of their elements.
 - Throws: `CancellationError` if the task or one of the operations was cancelled. Otherwise, the error of the last failed element if no operation succeeded.
 */
func allSettled<Element: Sendable, Value: Sendable>(_ elements: [Element], skipping isSkipped: (Error) -> Bool = { _ in false }, _ operation: @escaping @Sendable (Element) async throws -> Value) async throws -> [Value] {
	let results = await withTaskGroup(of: (Int, Result<Value, Error>).self) { group in
		for (index, element) in elements.enumerated() {
			group.addTask {
				do {
					return try await (index, .success(operation(element)))
				} catch {
					return (index, .failure(error))
				}
			}
		}
		var results = [Result<Value, Error>?](repeating: nil, count: elements.count)
		for await (index, result) in group {
			results[index] = result
		}
		return results.compactMap(\.self)
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
