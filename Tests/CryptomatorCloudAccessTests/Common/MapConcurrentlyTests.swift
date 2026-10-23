//
//  MapConcurrentlyTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 23.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class MapConcurrentlyTests: XCTestCase {
	func testReturnsValuesInOrderOfElements() async throws {
		let values = try await mapConcurrently([1, 2, 3, 4], limit: 4) { element in
			try await Task.sleep(for: .milliseconds(10 * (4 - element)))
			return element
		}
		XCTAssertEqual([1, 2, 3, 4], values)
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

		await fulfillment(of: [limitStarted], timeout: testWaitTimeout)
		await fulfillment(of: [limitExceeded], timeout: 0.2)
		gate.open()

		let values = try await value(of: mapping)
		XCTAssertEqual([1, 2, 3, 4], values)
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		let mapping = cancelledTask {
			try await mapConcurrently([1, 2], limit: 2) { $0 }
		}
		await XCTAssertThrowsErrorAsync(try await value(of: mapping)) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}
}
