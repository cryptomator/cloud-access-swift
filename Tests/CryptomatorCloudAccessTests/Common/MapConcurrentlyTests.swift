//
//  MapConcurrentlyTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 23.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessTestSupport
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct MapConcurrentlyTests {
		@Test
		func returnsValuesInOrderOfElements() async throws {
			let values = try await mapConcurrently([1, 2, 3, 4], limit: 4) { element in
				try await Task.sleep(for: .milliseconds(10 * (4 - element)))
				return element
			}
			#expect(values == [1, 2, 3, 4])
		}

		@Test
		func runsAtMostLimitOperationsAtOnce() async throws {
			let runningCount = OSAllocatedUnfairLock(initialState: 0)
			let gate = Gate()
			let limitStarted = TestSignal("two operations started", expectedCount: 2, allowsOverFulfillment: true)
			let limitExceeded = TestSignal("more than two operations ran at once", allowsOverFulfillment: true)
			let mapping = Task {
				try await mapConcurrently([1, 2, 3, 4], limit: 2) { element in
					let running = runningCount.withLock { count in
						count += 1
						return count
					}
					if running > 2 {
						limitExceeded.fulfill()
					} else {
						limitStarted.fulfill()
					}
					await gate.wait()
					runningCount.withLock { $0 -= 1 }
					return element
				}
			}

			await limitStarted.wait()
			await limitExceeded.expectNoFulfillment(within: .seconds(0.2))
			gate.open()

			let values = try await cancellingValue(of: mapping)
			#expect(values == [1, 2, 3, 4])
		}

		@Test
		func throwsCancellationErrorInCancelledTask() async {
			let mapping = cancelledTask {
				try await mapConcurrently([1, 2], limit: 2) { $0 }
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: mapping) }
		}
	}
}
