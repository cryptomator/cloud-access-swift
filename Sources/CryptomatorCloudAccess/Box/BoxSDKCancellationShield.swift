//
//  BoxSDKCancellationShield.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import BoxSdkGen
import Foundation

/**
 Awaits a Box SDK call in a task that doesn't inherit the cancellation of the current task. Otherwise, cancellation would end the call during the retry delay of its network client, before the SDK's work has finished.

 - Throws: `CancellationError` if the SDK reports that its request was cancelled, e.g., because its session was invalidated.
 */
func withBoxSDKCancellationShield<T: Sendable>(_ call: @escaping @concurrent @Sendable () async throws -> T) async throws -> T {
	do {
		return try await withoutCancellation(call)
	} catch let error as BoxNetworkError where error.error.map(isCancellationError) == true {
		throw CancellationError()
	}
}
