//
//  TestHelpersTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 17.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import Testing

extension UnitTests {
	struct TestHelpersTests {
		@Test
		func cancellingValueCancelsTaskAndWaitsForItWhenTimeoutRunsOut() async throws {
			let sleep = ManualSleep()
			let gracePeriodRequested = TestSignal("cancellingValue requested the grace period")
			let returned = TestSignal("cancellingValue returned")
			// The task ignores cancellation. Its wait runs out if the call doesn't request the grace period, so that a call that waits for the task without one fails instead of hanging.
			let task = Task { () throws -> Bool in
				await gracePeriodRequested.wait()
				return Task.isCancelled
			}
			let driver = Task {
				_ = await sleep.requests(count: 1)
				sleep.elapse()
				let requests = await sleep.requests(count: 2)
				#expect(requests == [.seconds(1), .seconds(5)])
				// Ends the task without letting the grace period run out, so the call returns only if it waits for the task. If it doesn't, the wait for its return runs out and fails the test.
				gracePeriodRequested.fulfill()
				await returned.wait()
				sleep.elapse()
			}
			var thrownError: Error?
			await withKnownIssue {
				do {
					_ = try await cancellingValue(of: task, timeout: .seconds(1), sleep: sleep.sleep)
				} catch {
					thrownError = error
				}
			} matching: { issue in
				issue.comments.contains { $0.rawValue == "Task did not finish within 1.0 seconds" }
			}
			returned.fulfill()
			await sleep.finishDriver(driver)
			#expect((thrownError as? UnfinishedTaskError)?.timeout == .seconds(1))
			#expect(try await task.value, "The timeout didn't cancel the task")
		}

		@Test
		func cancellingValueStopsWaitingForTaskWhenGracePeriodRunsOut() async {
			let sleep = ManualSleep()
			let returned = TestSignal("cancellingValue returned before the task finished")
			// The task ignores cancellation. Its wait runs out if the call doesn't return, so that a call that waits for the task beyond the grace period fails instead of hanging.
			let task = Task { () throws in
				await returned.wait()
			}
			let driver = Task {
				_ = await sleep.requests(count: 1)
				sleep.elapse()
				_ = await sleep.requests(count: 2)
				sleep.elapse()
			}
			var thrownError: Error?
			await withKnownIssue {
				do {
					_ = try await cancellingValue(of: task, timeout: .seconds(1), sleep: sleep.sleep)
				} catch {
					thrownError = error
				}
			} matching: { issue in
				issue.comments.contains { $0.rawValue == "Task did not finish within 1.0 seconds" }
			}
			returned.fulfill()
			await sleep.finishDriver(driver)
			#expect((thrownError as? UnfinishedTaskError)?.timeout == .seconds(1))
			_ = await task.result
		}

		@Test
		func signalWaitRecordsIssueWhenTimeoutRunsOut() async {
			let sleep = ManualSleep()
			let signal = TestSignal("signal", sleep: sleep.sleep)
			let driver = Task {
				_ = await sleep.requests(count: 1)
				sleep.elapse()
			}
			await withKnownIssue {
				await signal.wait(timeout: .seconds(1))
			} matching: { issue in
				issue.comments.contains { $0.rawValue == "\"signal\" was fulfilled 0 of 1 times within 1.0 seconds" }
			}
			await sleep.finishDriver(driver)
		}

		@Test
		func signalWaitRecordsIssueUntilExpectedCountIsReached() async {
			let sleep = ManualSleep()
			let signal = TestSignal("signal", expectedCount: 3, sleep: sleep.sleep)
			signal.fulfill()
			let driver = Task {
				_ = await sleep.requests(count: 1)
				signal.fulfill()
				sleep.elapse()
			}
			await withKnownIssue {
				await signal.wait(timeout: .seconds(1))
			} matching: { issue in
				issue.comments.contains { $0.rawValue == "\"signal\" was fulfilled 2 of 3 times within 1.0 seconds" }
			}
			await sleep.finishDriver(driver)
		}

		@Test
		func expectNoFulfillmentRecordsIssueForFulfillmentBeforeTheCall() async {
			let sleep = ManualSleep()
			let signal = TestSignal("signal", sleep: sleep.sleep)
			signal.fulfill()
			let driver = Task {
				_ = await sleep.requests(count: 1)
				sleep.elapse()
			}
			await withKnownIssue {
				await signal.expectNoFulfillment(within: .seconds(1))
			} matching: { issue in
				issue.comments.contains { $0.rawValue.hasPrefix("\"signal\" was fulfilled 1 times") }
			}
			await sleep.finishDriver(driver)
		}

		@Test
		func expectNoFulfillmentRecordsIssueForFulfillmentWithinTheWindow() async {
			let sleep = ManualSleep()
			let signal = TestSignal("signal", sleep: sleep.sleep)
			let driver = Task {
				_ = await sleep.requests(count: 1)
				signal.fulfill()
				sleep.elapse()
			}
			await withKnownIssue {
				await signal.expectNoFulfillment(within: .seconds(1))
			} matching: { issue in
				issue.comments.contains { $0.rawValue.hasPrefix("\"signal\" was fulfilled 1 times") }
			}
			await sleep.finishDriver(driver)
		}

		@Test
		func expectNoFulfillmentRecordsNoIssueWithoutFulfillment() async {
			let sleep = ManualSleep()
			let signal = TestSignal("signal", sleep: sleep.sleep)
			let driver = Task {
				_ = await sleep.requests(count: 1)
				sleep.elapse()
			}
			await signal.expectNoFulfillment(within: .seconds(1))
			await sleep.finishDriver(driver)
		}

		@Test
		func expectNoFulfillmentRecordsNoIssueForFulfillmentAfterTheWindow() async {
			let sleep = ManualSleep()
			let signal = TestSignal("signal", sleep: sleep.sleep)
			let driver = Task {
				_ = await sleep.requests(count: 1)
				sleep.elapse()
			}
			await signal.expectNoFulfillment(within: .seconds(1))
			await sleep.finishDriver(driver)
			signal.fulfill()
		}

		@Test
		func overFulfillmentRecordsIssue() {
			let signal = TestSignal("signal")
			signal.fulfill()
			withKnownIssue {
				signal.fulfill()
			} matching: { issue in
				issue.comments.contains { $0.rawValue == "\"signal\" was fulfilled 2 times, more than the expected 1" }
			}
		}

		@Test
		func overFulfillmentRecordsNoIssueIfAllowed() {
			let signal = TestSignal("signal", allowsOverFulfillment: true)
			signal.fulfill()
			signal.fulfill()
			#expect(signal.fulfillmentCount == 2)
		}
	}
}

/// A sleep that lasts until the test ends it, and that tells the test which durations were requested.
private final class ManualSleep: Sendable {
	private struct State {
		var requests: [Duration] = []
		var sleepers: [CheckedContinuation<Void, Never>] = []
		var watchers: [(count: Int, continuation: CheckedContinuation<[Duration], Never>)] = []
		var isWatchingStopped = false
	}

	private let state = OSAllocatedUnfairLock(initialState: State())

	@Sendable
	func sleep(_ duration: Duration) async throws {
		await withCheckedContinuation { continuation in
			let (requests, watchers) = state.withLock { state in
				state.requests.append(duration)
				state.sleepers.append(continuation)
				let requestCount = state.requests.count
				defer { state.watchers.removeAll { $0.count <= requestCount } }
				return (state.requests, state.watchers.filter { $0.count <= requestCount })
			}
			for watcher in watchers {
				watcher.continuation.resume(returning: requests)
			}
		}
	}

	/// Returns the requested durations once there are at least `count` of them, or once `finishDriver(_:)` stopped waiting for them.
	func requests(count: Int) async -> [Duration] {
		return await withCheckedContinuation { continuation in
			let requests = state.withLock { state in
				guard state.requests.count >= count || state.isWatchingStopped else {
					state.watchers.append((count, continuation))
					return [Duration]?.none
				}
				return state.requests
			}
			if let requests {
				continuation.resume(returning: requests)
			}
		}
	}

	/// Waits for the task that drives the sleeps. A driver that waits for a sleep the code under test never requested gets the requests so far, so that the test ends instead of hanging.
	func finishDriver(_ driver: Task<Void, Never>) async {
		stopWatching()
		await driver.value
	}

	private func stopWatching() {
		let (requests, watchers) = state.withLock { state in
			state.isWatchingStopped = true
			defer { state.watchers = [] }
			return (state.requests, state.watchers)
		}
		for watcher in watchers {
			watcher.continuation.resume(returning: requests)
		}
	}

	/// Ends every sleep that is running.
	func elapse() {
		let sleepers = state.withLock { state in
			defer { state.sleepers = [] }
			return state.sleepers
		}
		for sleeper in sleepers {
			sleeper.resume()
		}
	}
}
