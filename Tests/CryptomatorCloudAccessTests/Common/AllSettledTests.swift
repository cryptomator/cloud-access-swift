//
//  AllSettledTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessTestSupport
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct AllSettledTests {
		@Test
		func returnsEmptyResultForEmptyInput() async throws {
			let values = try await allSettled([Int](), limit: 2) { $0 }
			#expect(values == [])
		}

		@Test
		func returnsValuesOfSucceededOperationsInOrder() async throws {
			let values = try await allSettled([1, 2, 3, 4], limit: 4) { element in
				if element.isMultiple(of: 2) {
					throw CloudProviderError.itemNotFound
				}
				try await Task.sleep(for: .milliseconds(10 * (4 - element)))
				return element
			}
			#expect(values == [1, 3])
		}

		@Test
		func runsAtMostLimitOperationsAtOnce() async throws {
			try await assertRunsAtMostLimitOperationsAtOnce { try await allSettled($0, limit: $1, $2) }
		}

		@Test
		func cancellationStartsNoFurtherOperations() async throws {
			let startedCount = OSAllocatedUnfairLock(initialState: 0)
			let gate = Gate()
			let limitStarted = TestSignal("two operations started", expectedCount: 2, allowsOverFulfillment: true)
			let settling = Task {
				try await allSettled([1, 2, 3, 4], limit: 2) { element in
					startedCount.withLock { $0 += 1 }
					limitStarted.fulfill()
					await gate.wait()
					return element
				}
			}

			await limitStarted.wait()
			settling.cancel()
			gate.open()

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: settling) }
			#expect(startedCount.withLock { $0 } == 2)
		}

		@Test
		func throwsLastErrorIfAllOperationsFailed() async {
			await #expect(throws: CloudProviderError.noInternetConnection) {
				try await allSettled([CloudProviderError.itemNotFound, CloudProviderError.noInternetConnection], limit: 2) { error -> Int in
					throw error
				}
			}
		}

		@Test
		func returnsEmptyResultIfAllOperationsWereSkipped() async throws {
			let values = try await allSettled([1, 2], limit: 2, skipping: isItemNotFound) { _ -> Int in
				throw CloudProviderError.itemNotFound
			}
			#expect(values == [])
		}

		@Test
		func throwsErrorOfFailedOperationIfTheOthersWereSkipped() async {
			await #expect(throws: CloudProviderError.noInternetConnection) {
				try await allSettled([CloudProviderError.noInternetConnection, CloudProviderError.itemNotFound], limit: 2, skipping: isItemNotFound) { error -> Int in
					throw error
				}
			}
		}

		@Test
		func throwsCancellationErrorIfOneOperationWasCancelled() async {
			await #expect(throws: CancellationError.self) {
				try await allSettled([1, 2], limit: 2) { element in
					if element == 2 {
						throw CancellationError()
					}
					return element
				}
			}
		}

		@Test
		func throwsCancellationErrorInCancelledTask() async {
			let settling = cancelledTask {
				try await allSettled([1, 2], limit: 2) { $0 }
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: settling) }
		}
	}
}

private func isItemNotFound(_ error: Error) -> Bool {
	return error as? CloudProviderError == .itemNotFound
}
