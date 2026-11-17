//
//  AllSettledTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
@testable import CryptomatorCloudAccessCore

class AllSettledTests: XCTestCase {
	func testReturnsEmptyResultForEmptyInput() async throws {
		let values = try await allSettled([Int](), limit: 2) { $0 }
		XCTAssertEqual([], values)
	}

	func testReturnsValuesOfSucceededOperationsInOrder() async throws {
		let values = try await allSettled([1, 2, 3, 4], limit: 4) { element in
			if element.isMultiple(of: 2) {
				throw CloudProviderError.itemNotFound
			}
			try await Task.sleep(for: .milliseconds(10 * (4 - element)))
			return element
		}
		XCTAssertEqual([1, 3], values)
	}

	func testRunsAtMostLimitOperationsAtOnce() async throws {
		let runningCount = OSAllocatedUnfairLock(initialState: 0)
		let gate = Gate()
		let limitStarted = expectation(description: "two operations started")
		limitStarted.expectedFulfillmentCount = 2
		limitStarted.assertForOverFulfill = false
		let limitExceeded = expectation(description: "more than two operations ran at once")
		limitExceeded.isInverted = true
		limitExceeded.assertForOverFulfill = false
		let settling = Task {
			try await allSettled([1, 2, 3, 4], limit: 2) { element in
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

		await fulfillment(of: [limitStarted], timeout: testWaitTimeout)
		await fulfillment(of: [limitExceeded], timeout: 0.2)
		gate.open()

		let values = try await value(of: settling)
		XCTAssertEqual([1, 2, 3, 4], values)
	}

	func testCancellationStartsNoFurtherOperations() async throws {
		let startedCount = OSAllocatedUnfairLock(initialState: 0)
		let gate = Gate()
		let limitStarted = expectation(description: "two operations started")
		limitStarted.expectedFulfillmentCount = 2
		limitStarted.assertForOverFulfill = false
		let settling = Task {
			try await allSettled([1, 2, 3, 4], limit: 2) { element in
				startedCount.withLock { $0 += 1 }
				limitStarted.fulfill()
				await gate.wait()
				return element
			}
		}

		await fulfillment(of: [limitStarted], timeout: testWaitTimeout)
		settling.cancel()
		gate.open()

		await XCTAssertThrowsErrorAsync(try await value(of: settling)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertEqual(2, startedCount.withLock { $0 })
	}

	func testThrowsLastErrorIfAllOperationsFailed() async {
		await XCTAssertThrowsErrorAsync(try await allSettled([CloudProviderError.itemNotFound, CloudProviderError.noInternetConnection], limit: 2) { error -> Int in
			throw error
		}) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
		}
	}

	func testReturnsEmptyResultIfAllOperationsWereSkipped() async throws {
		let values = try await allSettled([1, 2], limit: 2, skipping: isItemNotFound) { _ -> Int in
			throw CloudProviderError.itemNotFound
		}
		XCTAssertEqual([], values)
	}

	func testThrowsErrorOfFailedOperationIfTheOthersWereSkipped() async {
		await XCTAssertThrowsErrorAsync(try await allSettled([CloudProviderError.noInternetConnection, CloudProviderError.itemNotFound], limit: 2, skipping: isItemNotFound) { error -> Int in
			throw error
		}) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
		}
	}

	func testThrowsCancellationErrorIfOneOperationWasCancelled() async {
		await XCTAssertThrowsErrorAsync(try await allSettled([1, 2], limit: 2) { element in
			if element == 2 {
				throw CancellationError()
			}
			return element
		}) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		let settling = cancelledTask {
			try await allSettled([1, 2], limit: 2) { $0 }
		}
		await XCTAssertThrowsErrorAsync(try await value(of: settling)) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}
}

private func isItemNotFound(_ error: Error) -> Bool {
	return error as? CloudProviderError == .itemNotFound
}
