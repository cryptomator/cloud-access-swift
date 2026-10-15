//
//  AllSettledTests.swift
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

class AllSettledTests: XCTestCase {
	func testReturnsEmptyResultForEmptyInput() async throws {
		let values = try await allSettled([Int]()) { $0 }
		XCTAssertEqual([], values)
	}

	func testReturnsValuesOfSucceededOperationsInOrder() async throws {
		let values = try await allSettled([1, 2, 3, 4]) { element in
			if element.isMultiple(of: 2) {
				throw CloudProviderError.itemNotFound
			}
			try await Task.sleep(for: .milliseconds(10 * (4 - element)))
			return element
		}
		XCTAssertEqual([1, 3], values)
	}

	func testThrowsLastErrorIfAllOperationsFailed() async {
		await XCTAssertThrowsErrorAsync(try await allSettled([CloudProviderError.itemNotFound, CloudProviderError.noInternetConnection]) { error -> Int in
			throw error
		}) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
		}
	}

	func testThrowsCancellationErrorIfOneOperationWasCancelled() async {
		await XCTAssertThrowsErrorAsync(try await allSettled([1, 2]) { element in
			if element == 2 {
				throw CancellationError()
			}
			return element
		}) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		let settling = cancelledTask {
			try await allSettled([1, 2]) { $0 }
		}
		await XCTAssertThrowsErrorAsync(try await value(of: settling)) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}
}
