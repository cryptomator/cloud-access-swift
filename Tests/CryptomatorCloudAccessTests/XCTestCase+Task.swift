//
//  XCTestCase+Task.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

struct UnfinishedTaskError: Error {}

/// How long a test waits for a step that it expects to happen. The CI simulator stalls for over half a minute at times, so a shorter wait fails tests that aren't broken.
let testWaitTimeout: TimeInterval = 60

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

extension XCTestCase {
	/**
	 Waits for the value of a task that the test started.

	 If the task doesn't finish within the timeout, the test fails instead of hanging the test run. The task is then cancelled and given a moment to finish, which makes it less likely to send requests during later tests. A task group can't serve as the timeout, because it only returns once all of its child tasks returned.
	 */
	func value<Value: Sendable>(of task: Task<Value, Error>, timeout: TimeInterval = testWaitTimeout, file: StaticString = #filePath, line: UInt = #line) async throws -> Value {
		let finished = XCTestExpectation(description: "task finished")
		// An expectation can only be waited on once.
		let finishedAfterCancellation = XCTestExpectation(description: "task finished after cancellation")
		Task {
			_ = await task.result
			finished.fulfill()
			finishedAfterCancellation.fulfill()
		}
		guard await XCTWaiter().fulfillment(of: [finished], timeout: timeout) == .completed else {
			task.cancel()
			_ = await XCTWaiter().fulfillment(of: [finishedAfterCancellation], timeout: 5)
			XCTFail("Task did not finish within \(timeout) seconds", file: file, line: line)
			throw UnfinishedTaskError()
		}
		return try await task.value
	}

	/// The files with a UUID name in the temporary directory, like the temporary files of the parts of an upload. System services of the simulator write other items there.
	func uuidNamedTemporaryFiles() throws -> Set<String> {
		let urls = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: [.isRegularFileKey])
		return try Set(urls.filter { try UUID(uuidString: $0.lastPathComponent) != nil && $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }.map(\.lastPathComponent))
	}

	func assertThrowsCancellationErrorInCancelledTask(_ provider: CloudProvider, file: StaticString = #filePath, line: UInt = #line) async {
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
			await XCTAssertThrowsErrorAsync(try await value(of: cancelledTask(operation), file: file, line: line), "\(name) did not throw", file: file, line: line) { error in
				XCTAssertTrue(error is CancellationError, "\(name) threw \(error)", file: file, line: line)
			}
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path), file: file, line: line)
	}
}
