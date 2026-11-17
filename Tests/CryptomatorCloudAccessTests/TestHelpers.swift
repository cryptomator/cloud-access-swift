//
//  TestHelpers.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 17.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

// MARK: - Tasks

/// How long a test waits for a step that it expects to happen. The CI simulator stalls for over half a minute at times, so a shorter wait fails tests that aren't broken.
let testWaitTimeout: TimeInterval = 60

struct UnfinishedTaskError: Error, CustomStringConvertible {
	let timeout: Duration

	var description: String {
		return "Task did not finish within \(timeout)"
	}
}

func taskSleep(for duration: Duration) async throws {
	try await Task.sleep(for: duration)
}

/// Starts the operation in a task that is already cancelled when the operation begins.
func cancelledTask<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) -> Task<Value, Error> {
	return Task {
		withUnsafeCurrentTask { $0?.cancel() }
		return try await operation()
	}
}

/// Cancels a task from a request handler, once the test stored the task.
final class TaskCanceller<Value: Sendable>: Sendable {
	private let task = OSAllocatedUnfairLock<Task<Value, Error>?>(initialState: nil)
	private let taskStored = DispatchSemaphore(value: 0)

	func start(_ operation: @escaping @Sendable () async throws -> Value) -> Task<Value, Error> {
		let task = Task {
			try await operation()
		}
		self.task.withLock { $0 = task }
		taskStored.signal()
		return task
	}

	func cancel() {
		_ = taskStored.wait(timeout: .now() + testWaitTimeout)
		task.withLock { $0 }?.cancel()
	}
}

/**
 Waits for the value of a task that the test started.

 If the task doesn't finish within the timeout, it is cancelled and given up to 5 seconds to finish, which makes it less likely to send requests during later tests. The test then fails instead of hanging the test run, and `UnfinishedTaskError` is thrown. Every timer of the call runs out when `sleep` returns, and never if it throws.
 */
func cancellingValue<Value: Sendable>(of task: Task<Value, Error>, timeout: Duration = .seconds(testWaitTimeout), sleep: @escaping @Sendable (Duration) async throws -> Void = taskSleep(for:), sourceLocation: SourceLocation = #_sourceLocation) async throws -> Value {
	if let result = await result(of: task, timeout: timeout, sleep: sleep) {
		return try result.get()
	}
	task.cancel()
	_ = await result(of: task, timeout: .seconds(5), sleep: sleep)
	let error = UnfinishedTaskError(timeout: timeout)
	Issue.record(Comment(rawValue: error.description), sourceLocation: sourceLocation)
	throw error
}

/// Runs `body` while `task` waits for `release`. If `body` throws, it fulfills `release` and waits for the task before rethrowing. Otherwise the task would run on into a later test, which its timed-out wait would fail.
func releasingOnError<Value>(_ task: Task<some Sendable, Error>, by release: TestSignal, sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Value) async throws -> Value {
	do {
		return try await body()
	} catch {
		release.fulfill()
		_ = try? await cancellingValue(of: task, sourceLocation: sourceLocation)
		throw error
	}
}

/**
 Returns the result of a task, or `nil` once the timeout runs out first, leaving the task running.

 A task group can't serve as the timeout, because it only returns once all of its child tasks returned, and a child that awaits the task's result doesn't end when the group cancels it.
 */
private func result<Value: Sendable>(of task: Task<Value, Error>, timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) async -> Result<Value, Error>? {
	let lockedContinuation = OSAllocatedUnfairLock<CheckedContinuation<Result<Value, Error>?, Never>?>(initialState: nil)
	let lockedTimer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
	let resume: @Sendable (Result<Value, Error>?) -> Void = { result in
		lockedContinuation.withLock { continuation in
			defer { continuation = nil }
			return continuation
		}?.resume(returning: result)
		lockedTimer.withLock { $0 }?.cancel()
	}
	return await withCheckedContinuation { continuation in
		lockedContinuation.withLock { $0 = continuation }
		lockedTimer.withLock { timer in
			timer = Task {
				guard await (try? sleep(timeout)) != nil else {
					return
				}
				resume(nil)
			}
		}
		Task {
			let result = await task.result
			resume(result)
		}
	}
}

// MARK: - Signals

/**
 A step of a test that the test waits for, which code on any thread or task can signal.

 It fails the test when it is fulfilled more often than expected, unless it allows over-fulfillment. The timeout of `wait(timeout:)` runs out when `sleep` returns, and never if it throws. The window of `expectNoFulfillment(within:)` ends either way.
 */
final class TestSignal: Sendable {
	private struct Waiter {
		let id: UUID
		let continuation: CheckedContinuation<Bool, Never>
		var timer: Task<Void, Never>?
	}

	private struct State {
		var fulfillmentCount = 0
		var waiters: [Waiter] = []
	}

	let expectedCount: Int
	let allowsOverFulfillment: Bool
	private let name: String
	private let sleep: @Sendable (Duration) async throws -> Void
	private let sourceLocation: SourceLocation
	private let state = OSAllocatedUnfairLock(initialState: State())

	init(_ name: String, expectedCount: Int = 1, allowsOverFulfillment: Bool = false, sleep: @escaping @Sendable (Duration) async throws -> Void = taskSleep(for:), sourceLocation: SourceLocation = #_sourceLocation) {
		self.name = name
		self.expectedCount = expectedCount
		self.allowsOverFulfillment = allowsOverFulfillment
		self.sleep = sleep
		self.sourceLocation = sourceLocation
	}

	var fulfillmentCount: Int {
		return state.withLock { $0.fulfillmentCount }
	}

	func fulfill() {
		let (fulfillmentCount, waiters) = state.withLock { state in
			state.fulfillmentCount += 1
			guard state.fulfillmentCount >= expectedCount else {
				return (state.fulfillmentCount, [Waiter]())
			}
			defer { state.waiters = [] }
			return (state.fulfillmentCount, state.waiters)
		}
		for waiter in waiters {
			waiter.timer?.cancel()
			waiter.continuation.resume(returning: true)
		}
		if fulfillmentCount > expectedCount, !allowsOverFulfillment {
			Issue.record("\"\(name)\" was fulfilled \(fulfillmentCount) times, more than the expected \(expectedCount)", sourceLocation: sourceLocation)
		}
	}

	/// Returns once the signal was fulfilled the expected number of times, and fails the test if the timeout runs out first.
	func wait(timeout: Duration = .seconds(testWaitTimeout), sourceLocation: SourceLocation = #_sourceLocation) async {
		let id = UUID()
		let isFulfilled = await withCheckedContinuation { continuation in
			let isFulfilled = state.withLock { state in
				guard state.fulfillmentCount < expectedCount else {
					return true
				}
				state.waiters.append(Waiter(id: id, continuation: continuation))
				return false
			}
			guard !isFulfilled else {
				continuation.resume(returning: true)
				return
			}
			let timer = Task {
				guard await (try? self.sleep(timeout)) != nil else {
					return
				}
				let waiter = self.state.withLock { state in
					state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0) }
				}
				waiter?.continuation.resume(returning: false)
			}
			let isWaiting = state.withLock { state in
				guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
					return false
				}
				state.waiters[index].timer = timer
				return true
			}
			if !isWaiting {
				timer.cancel()
			}
		}
		if !isFulfilled {
			Issue.record("\"\(name)\" was fulfilled \(fulfillmentCount) of \(expectedCount) times within \(timeout)", sourceLocation: sourceLocation)
		}
	}

	/// Fails the test if the signal was fulfilled between its creation and the end of the window. A fulfillment after the window doesn't fail it.
	func expectNoFulfillment(within window: Duration, sourceLocation: SourceLocation = #_sourceLocation) async {
		try? await sleep(window)
		let fulfillmentCount = fulfillmentCount
		if fulfillmentCount > 0 {
			Issue.record("\"\(name)\" was fulfilled \(fulfillmentCount) times, but must not be fulfilled within \(window)", sourceLocation: sourceLocation)
		}
	}
}

/// A step that a task waits for until the test opens it. Its wait has no timeout. A task that the test keeps suspended while it checks that a call returns therefore waits on a `TestSignal`, so that a call that waits for the task fails instead of hanging the run, and the test checks that call in `releasingOnError(_:by:_:)`.
final class Gate: Sendable {
	private let state = OSAllocatedUnfairLock(initialState: (isOpen: false, waiters: [CheckedContinuation<Void, Never>]()))

	func wait() async {
		await withCheckedContinuation { continuation in
			let isOpen = state.withLock { state in
				if !state.isOpen {
					state.waiters.append(continuation)
				}
				return state.isOpen
			}
			if isOpen {
				continuation.resume()
			}
		}
	}

	func open() {
		let waiters = state.withLock { state in
			state.isOpen = true
			defer { state.waiters = [] }
			return state.waiters
		}
		for waiter in waiters {
			waiter.resume()
		}
	}
}

// MARK: - Cleanup

/// Records a failed removal as an issue of the running test instead of throwing, because a suite's `deinit` can't throw.
func removeItemRecordingFailure(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
	do {
		try FileManager.default.removeItem(at: url)
	} catch {
		Issue.record(error, sourceLocation: sourceLocation)
	}
}

// MARK: - Library

/// The files with a UUID name in the process's temporary folder, like the temporary files of the parts of an upload. It leaves out the folders of the library's objects, which lie there too.
func uuidNamedTemporaryFiles() throws -> Set<String> {
	let urls = try FileManager.default.contentsOfDirectory(at: ProcessTemporaryDirectory.shared.directoryURL(), includingPropertiesForKeys: [.isRegularFileKey])
	return try Set(urls.filter { try UUID(uuidString: $0.lastPathComponent) != nil && $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }.map(\.lastPathComponent))
}

func assertThrowsCancellationErrorInCancelledTask(_ provider: CloudProvider, sourceLocation: SourceLocation = #_sourceLocation) async {
	let cloudPath = CloudPath("/foo")
	let otherCloudPath = CloudPath("/bar")
	let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
	let operations: [(String, @Sendable () async throws -> Void)] = [
		("fetchItemMetadata", { _ = try await provider.fetchItemMetadata(at: cloudPath) }),
		("fetchItemList", { _ = try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil) }),
		("downloadFile", { _ = try await provider.downloadFile(from: cloudPath, to: localURL, progress: nil, onTaskCreation: nil) }),
		("uploadFile", { _ = try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: true, progress: nil, onTaskCreation: nil) }),
		("createFolder", { try await provider.createFolder(at: cloudPath) }),
		("deleteFile", { try await provider.deleteFile(at: cloudPath) }),
		("deleteFolder", { try await provider.deleteFolder(at: cloudPath) }),
		("moveFile", { try await provider.moveFile(from: cloudPath, to: otherCloudPath) }),
		("moveFolder", { try await provider.moveFolder(from: cloudPath, to: otherCloudPath) })
	]
	for (name, operation) in operations {
		await #expect(throws: CancellationError.self, "\(name)", sourceLocation: sourceLocation) {
			try await cancellingValue(of: cancelledTask(operation), sourceLocation: sourceLocation)
		}
	}
	#expect(!FileManager.default.fileExists(atPath: localURL.path), sourceLocation: sourceLocation)
}
