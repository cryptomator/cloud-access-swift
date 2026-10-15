//
//  BoxCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import BoxSdkGen
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class BoxCloudProviderTests: XCTestCase {
	func testThrowsCancellationErrorInCancelledTask() async throws {
		let provider = try BoxCloudProvider(credential: BoxCredential(auth: BoxDeveloperTokenAuth(token: "")))
		await assertThrowsCancellationErrorInCancelledTask(provider)
	}

	func testCancellationShieldAwaitsCallInUncancelledTask() async throws {
		let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
		let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
		let shieldedCall = _Concurrency.Task {
			try await withBoxSDKCancellationShield {
				startedContinuation.yield()
				for await _ in gate {
					break
				}
				return _Concurrency.Task.isCancelled
			}
		}
		for await _ in started {
			break
		}
		shieldedCall.cancel()
		gateContinuation.yield()
		let callWasCancelled = try await shieldedCall.value
		XCTAssertFalse(callWasCancelled)
	}

	func testCancellationShieldConvertsCancelledRequestToCancellationError() async {
		let cancellationErrors: [Error] = [URLError(.cancelled), NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)]
		for cancellationError in cancellationErrors {
			await XCTAssertThrowsErrorAsync(try await withBoxSDKCancellationShield { throw BoxNetworkError(message: "", error: cancellationError) }) { error in
				XCTAssertTrue(error is CancellationError)
			}
		}
	}

	func testCancellationShieldRethrowsOtherErrors() async {
		await XCTAssertThrowsErrorAsync(try await withBoxSDKCancellationShield { throw BoxNetworkError(message: "", error: URLError(.timedOut)) }) { error in
			XCTAssertEqual(.timedOut, ((error as? BoxNetworkError)?.error as? URLError)?.code)
		}
		await XCTAssertThrowsErrorAsync(try await withBoxSDKCancellationShield { throw BoxNetworkError(message: "") }) { error in
			XCTAssertTrue(error is BoxNetworkError)
		}
	}
}
