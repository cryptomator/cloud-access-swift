//
//  XCTestCase+BlockingAwait.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import XCTest

extension XCTestCase {
	/**
	 Runs the operation and blocks until it finishes or the timeout elapses.

	 This is meant for the class-level `setUp()` and `tearDown()`, which can't be async. It spins the current run loop while waiting, because several SDKs deliver their callbacks on the main queue, which a semaphore would block.
	 */
	@discardableResult
	static func blockingAwait<Value: Sendable>(timeout: TimeInterval, _ operation: @escaping @Sendable () async throws -> Value) throws -> Value {
		let lockedResult = OSAllocatedUnfairLock<Result<Value, Error>?>(initialState: nil)
		let task = Task {
			let result: Result<Value, Error>
			do {
				result = try await .success(operation())
			} catch {
				result = .failure(error)
			}
			lockedResult.withLock { $0 = result }
		}
		let timeoutDate = Date(timeIntervalSinceNow: timeout)
		while timeoutDate.timeIntervalSinceNow > 0 {
			if let result = lockedResult.withLock({ $0 }) {
				return try result.get()
			}
			RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
		}
		task.cancel()
		throw IntegrationTestError.oneTimeSetUpTimeout
	}
}
