//
//  OnTaskCreationAssertions.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 27.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

/// Records how a transfer calls its `onTaskCreation` closure: the states of the tasks it hands over, and whether the closure had returned when the transfer's request arrived.
final class OnTaskCreationProbe: Sendable {
	private let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
	private let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)

	/// An `onTaskCreation` closure that records the task's state and returns after 100 ms, so that a transfer that resumes its task without awaiting the closure sends its request before the closure returns.
	func onTaskCreation<SessionTask: URLSessionTask>() -> @concurrent @Sendable (SessionTask) async -> Void {
		return { task in
			self.taskStates.withLock { $0.append(task.state) }
			try? await Task.sleep(for: .milliseconds(100))
			self.onTaskCreationReturned.withLock { $0 = true }
		}
	}

	/// Expects that `onTaskCreation` returned. Call it when the transfer's request arrives.
	func expectOnTaskCreationReturned(sourceLocation: SourceLocation = #_sourceLocation) {
		#expect(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned", sourceLocation: sourceLocation)
	}

	/// Expects that `onTaskCreation` was called once, with a suspended task.
	func expectAwaited(sourceLocation: SourceLocation = #_sourceLocation) {
		#expect(taskStates.withLock { $0 } == [.suspended], sourceLocation: sourceLocation)
	}
}

/// An `onTaskCreation` closure that cancels the Swift task awaiting the transfer, not the `URLSessionTask` it receives.
func cancellingOnTaskCreation<SessionTask: URLSessionTask>() -> @concurrent @Sendable (SessionTask) async -> Void {
	return { _ in
		withUnsafeCurrentTask { $0?.cancel() }
	}
}

/// Expects that `transfer`, whose `onTaskCreation` cancels it, throws `CancellationError` without resuming its task. The response to the transfer's task must be the last one queued on `URLProtocolMock`.
func expectCancelledBeforeResume(_ transfer: @escaping @Sendable () async throws -> CloudItemMetadata, sourceLocation: SourceLocation = #_sourceLocation) async {
	await #expect(throws: CancellationError.self, sourceLocation: sourceLocation) {
		try await cancellingValue(of: Task { try await transfer() }, sourceLocation: sourceLocation)
	}
	#expect(URLProtocolMock.requestHandler.count == 1, "The transfer's task must not be resumed after onTaskCreation cancelled it", sourceLocation: sourceLocation)
}
