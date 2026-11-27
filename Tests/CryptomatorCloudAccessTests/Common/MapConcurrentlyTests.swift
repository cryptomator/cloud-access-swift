//
//  MapConcurrentlyTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 23.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessTestSupport
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct MapConcurrentlyTests {
		@Test
		func returnsValuesInOrderOfElements() async throws {
			let values = try await mapConcurrently([1, 2, 3, 4], limit: 4) { element in
				try await Task.sleep(for: .milliseconds(10 * (4 - element)))
				return element
			}
			#expect(values == [1, 2, 3, 4])
		}

		@Test
		func runsAtMostLimitOperationsAtOnce() async throws {
			try await assertRunsAtMostLimitOperationsAtOnce { try await mapConcurrently($0, limit: $1, $2) }
		}

		@Test
		func throwsCancellationErrorInCancelledTask() async {
			let mapping = cancelledTask {
				try await mapConcurrently([1, 2], limit: 2) { $0 }
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: mapping) }
		}
	}
}
