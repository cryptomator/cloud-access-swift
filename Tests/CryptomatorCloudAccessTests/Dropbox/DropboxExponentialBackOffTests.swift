//
//  DropboxExponentialBackOffTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 10.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Promises
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
		let startTime = DispatchTime.now()
		await XCTAssertThrowsErrorAsync(try await provider.retryWithExponentialBackoff({
			return Promise(DropboxError.internalServerError)
		}, condition: provider.shouldRetryForError).async()) { error in
			let durationNanoTime = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
			let duration = Double(durationNanoTime) / 1_000_000_000
			XCTAssert(duration >= 15)
			guard case DropboxError.internalServerError = error else {
				XCTFail("Returned the wrong error")
				return
			}
		}
	}

	func testWaitsWithRateLimitBackoff() async throws {
		DropboxSetup.constants = DropboxSetup(appKey: "", sharedContainerIdentifier: "", keychainService: "", forceForegroundSession: true)
		let credential = DropboxCredential(tokenUID: "testToken")
		let provider = DropboxCloudProvider(credential: credential)
		let expectedMinimumDuration = 5.0 // 5 Attempts * retry after 1s
		let expectedMaximumDuration = 7.5 // 5 Attempts * (retry after 1s + maxJitter) where maxJitter := 0.5s
		let startTime = DispatchTime.now()
		await XCTAssertThrowsErrorAsync(try await provider.retryWithExponentialBackoff({
			return Promise(DropboxError.rateLimitError(retryAfter: 1))
		}, condition: provider.shouldRetryForError).async()) { error in
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
}
