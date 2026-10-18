//
//  DropboxExponentialBackOffTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 10.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DropboxExponentialBackOffTests: XCTestCase {
	func testWaitsExponentially() async throws {
		DropboxSetup.constants = DropboxSetup(appKey: "", sharedContainerIdentifier: "", keychainService: "", forceForegroundSession: true)
		let credential = DropboxCredential(tokenUID: "testToken")
		let provider = DropboxCloudProvider(credential: credential)
		let attempts = OSAllocatedUnfairLock(initialState: 0)
		let startTime = DispatchTime.now()
		await XCTAssertThrowsErrorAsync(try await provider.retryWithExponentialBackoff({ () async throws -> Void in
			attempts.withLock { $0 += 1 }
			throw DropboxError.internalServerError
		}, condition: provider.shouldRetryForError)) { error in
			let durationNanoTime = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
			let duration = Double(durationNanoTime) / 1_000_000_000
			XCTAssert(duration >= 15)
			guard case DropboxError.internalServerError = error else {
				XCTFail("Returned the wrong error")
				return
			}
		}
		XCTAssertEqual(6, attempts.withLock { $0 })
	}

	func testWaitsWithRateLimitBackoff() async throws {
		DropboxSetup.constants = DropboxSetup(appKey: "", sharedContainerIdentifier: "", keychainService: "", forceForegroundSession: true)
		let credential = DropboxCredential(tokenUID: "testToken")
		let provider = DropboxCloudProvider(credential: credential)
		let expectedMinimumDuration = 5.0 // 5 Attempts * retry after 1s
		// 5 retries after 1s plus up to 0.5s jitter take at most 7.5s. The bound leaves room for CI stalls but stays below the 15.5s minimum of the exponential backoff, so the test still fails if retryAfter is ignored.
		let expectedMaximumDuration = 15.0
		let startTime = DispatchTime.now()
		await XCTAssertThrowsErrorAsync(try await provider.retryWithExponentialBackoff({ () async throws -> Void in
			throw DropboxError.rateLimitError(retryAfter: 1)
		}, condition: provider.shouldRetryForError)) { error in
			let durationNanoTime = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
			let duration = Double(durationNanoTime) / 1_000_000_000
			XCTAssert(duration >= expectedMinimumDuration)
			XCTAssert(duration <= expectedMaximumDuration)
			guard case DropboxError.rateLimitError = error else {
				XCTFail("Returned the wrong error")
				return
			}
		}
	}

	func testThrowsCancellationErrorWhenCancelledDuringBackoff() async throws {
		DropboxSetup.constants = DropboxSetup(appKey: "", sharedContainerIdentifier: "", keychainService: "", forceForegroundSession: true)
		let credential = DropboxCredential(tokenUID: "testToken")
		let provider = DropboxCloudProvider(credential: credential)
		let attempts = OSAllocatedUnfairLock(initialState: 0)
		let firstAttemptFailed = XCTestExpectation(description: "first attempt failed")
		let retrying = Task {
			try await provider.retryWithExponentialBackoff({ () async throws -> Void in
				attempts.withLock { $0 += 1 }
				firstAttemptFailed.fulfill()
				throw DropboxError.rateLimitError(retryAfter: 60)
			}, condition: provider.shouldRetryForError)
		}
		await fulfillment(of: [firstAttemptFailed], timeout: testWaitTimeout)
		retrying.cancel()
		await XCTAssertThrowsErrorAsync(try await value(of: retrying)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertEqual(1, attempts.withLock { $0 })
	}
}
