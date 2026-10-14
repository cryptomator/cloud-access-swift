//
//  SDKContinuationTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class SDKContinuationTests: XCTestCase {
	func testResumesExactlyOnceUnderConcurrentDoubleCompletion() async throws {
		for _ in 0 ..< 1000 {
			// Resuming the underlying continuation twice would trap.
			let value: Int = try await withSDKContinuation { resumer in
				for completion in 0 ..< 2 {
					DispatchQueue.global().async {
						resumer.resume(returning: completion)
					}
				}
			}
			XCTAssert((0 ..< 2).contains(value))
		}
	}

	func testPropagatesError() async {
		do {
			try await withSDKContinuation { (resumer: Resumer<Void>) in
				resumer.resume(throwing: CloudProviderError.itemNotFound)
			}
			XCTFail("Expected withSDKContinuation to throw")
		} catch {
			XCTAssertEqual(.itemNotFound, error as? CloudProviderError)
		}
	}

	func testMainActorVariantStartsOnMainThread() async throws {
		let startedOnMainThread = try await Task.detached { () -> Bool in
			try await withMainActorSDKContinuation { resumer in
				resumer.resume(returning: Thread.isMainThread)
			}
		}.value
		XCTAssertTrue(startedOnMainThread)
	}
}
