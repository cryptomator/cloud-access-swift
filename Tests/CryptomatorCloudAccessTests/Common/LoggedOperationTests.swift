//
//  LoggedOperationTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct LoggedOperationTests {
		private static func convertToItemNotFound(_ error: Error) -> Error {
			return CloudProviderError.itemNotFound
		}

		@Test
		func successLogsOnlyCallAndReturnsValue() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}

			let value = try await performLogged("operation(argument)", by: "TestProvider", convert: LoggedOperationTests.convertToItemNotFound) { 42 }

			#expect(value == 42)
			#expect(logCapture.messages.filter { $0.hasPrefix("TestProvider:") } == ["TestProvider: operation(argument) called"])
		}

		@Test
		func failureLogsErrorBeforeConversionAndThrowsConvertedError() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let error: any Error = URLError(.badServerResponse)

			await #expect(throws: CloudProviderError.itemNotFound) {
				try await performLogged("operation(argument)", by: "TestProvider", convert: LoggedOperationTests.convertToItemNotFound) { () async throws -> Int in
					throw error
				}
			}

			#expect(logCapture.messages.filter { $0.hasPrefix("TestProvider:") } == ["TestProvider: operation(argument) called", "TestProvider: operation(argument) failed with error: \(error)"])
		}
	}
}
