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
	func testWaitsExponentially() throws {
		DropboxSetup.constants = DropboxSetup(appKey: "", sharedContainerIdentifier: "", keychainService: "", forceForegroundSession: true)
		let credential = DropboxCredential(tokenUid: "testToken")
		let provider = DropboxCloudProvider(with: credential)
		let expectation = XCTestExpectation(description: "")
		let startTime = DispatchTime.now()
		provider.retryWithExponentialBackoff({
			return Promise(DropboxError.rateLimitError)
		}, condition: provider.shouldRetryForError)
			.catch { error in
				let durationNanoTime = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
				let duration = Double(durationNanoTime) / 1_000_000_000
				XCTAssert(duration >= 15)
				guard case DropboxError.rateLimitError = error else {
					XCTFail("Returned the wrong error")
					return
				}
			}.always {
				expectation.fulfill()
			}
		wait(for: [expectation], timeout: 20.0)
	}
}
