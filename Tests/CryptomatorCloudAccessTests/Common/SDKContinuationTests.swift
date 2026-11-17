//
//  SDKContinuationTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct SDKContinuationTests {
		@Test
		func resumesExactlyOnceUnderConcurrentDoubleCompletion() async throws {
			for _ in 0 ..< 1000 {
				// Resuming the underlying continuation twice would trap.
				let value: Int = try await withSDKContinuation { resumer in
					for completion in 0 ..< 2 {
						DispatchQueue.global().async {
							resumer.resume(returning: completion)
						}
					}
				}
				#expect((0 ..< 2).contains(value))
			}
		}

		@Test
		func propagatesError() async {
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await withSDKContinuation { (resumer: Resumer<Void>) in
					resumer.resume(throwing: CloudProviderError.itemNotFound)
				}
			}
		}
	}
}
