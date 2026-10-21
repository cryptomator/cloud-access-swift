//
//  SleepRecorder.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

/// Records the waits before retries instead of waiting.
final class SleepRecorder: Sendable {
	private let recordedDurations = OSAllocatedUnfairLock(initialState: [Duration]())

	var durations: [Duration] {
		return recordedDurations.withLock { $0 }
	}

	func sleep(for duration: Duration) {
		recordedDurations.withLock { $0.append(duration) }
	}
}
