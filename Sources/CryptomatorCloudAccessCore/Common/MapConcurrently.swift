//
//  MapConcurrently.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 23.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Runs the operation for all elements concurrently, but at most `limit` operations at a time.

 - Returns: The values of the operations, in the order of their elements.
 - Throws: The first error that an operation throws, or else `CancellationError` if the task is cancelled before every operation started. Before throwing, cancels the running operations and waits until they finished.
 */
func mapConcurrently<Element: Sendable, Value: Sendable>(_ elements: [Element], limit: Int, _ operation: @escaping @Sendable (Element) async throws -> Value) async throws -> [Value] {
	return try await withThrowingTaskGroup(of: (Int, Value).self) { group in
		var values = [Value?](repeating: nil, count: elements.count)
		for (index, element) in elements.enumerated() {
			if index >= limit, let (finishedIndex, value) = try await group.next() {
				values[finishedIndex] = value
			}
			try Task.checkCancellation()
			group.addTask {
				return try await (index, operation(element))
			}
		}
		for try await (index, value) in group {
			values[index] = value
		}
		return values.compactMap(\.self)
	}
}
