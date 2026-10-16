//
//  AsyncSemaphore.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// A counting semaphore whose waiters are resumed in the order they arrived.
actor AsyncSemaphore {
	private var availablePermits: Int
	private var waiters: [CheckedContinuation<Void, Never>] = []

	init(permits: Int) {
		self.availablePermits = permits
	}

	func acquire() async {
		if availablePermits > 0 {
			availablePermits -= 1
			return
		}
		await withCheckedContinuation { waiters.append($0) }
	}

	func release() {
		if waiters.isEmpty {
			availablePermits += 1
		} else {
			waiters.removeFirst().resume()
		}
	}

	/**
	 Runs the operation while it holds a permit, for at most the budget.

	 An operation that takes longer is cancelled best effort, and `IntegrationTestError.budgetExceeded` is thrown. It is left running without the permit, because SDK calls don't respond to cancellation, so that a hanging operation can't keep the permit for the rest of the run.

	 A caller that is cancelled before it gets the permit still waits for one, then releases it without running the operation. A caller that is cancelled later cancels the operation best effort and keeps the permit until the operation returns or the budget is exceeded.
	 */
	nonisolated func withPermit<T: Sendable>(budget: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
		await acquire()
		if Task.isCancelled {
			await release()
			throw CancellationError()
		}
		// The operation's own errors are passed as the task's value, so that only the timeout surfaces as `UnfinishedTaskError`.
		let task = Task<Result<T, Error>, Error> {
			do {
				return try await .success(operation())
			} catch {
				return .failure(error)
			}
		}
		let result: Result<T, Error>
		do {
			result = try await withTaskCancellationHandler {
				try await value(of: task, timeout: budget)
			} onCancel: {
				task.cancel()
			}
		} catch let error as UnfinishedTaskError {
			task.cancel()
			await release()
			throw IntegrationTestError.budgetExceeded(error.timeout)
		} catch {
			await release()
			throw error
		}
		await release()
		return try result.get()
	}
}

extension IntegrationProvider {
	private static let semaphores: [IntegrationProvider: AsyncSemaphore] = Dictionary(uniqueKeysWithValues: allCases.map { ($0, AsyncSemaphore(permits: $0.concurrencyLimit)) })

	/// Shared by all vault formats of the provider, because they share an account.
	var semaphore: AsyncSemaphore {
		return IntegrationProvider.semaphores[self]!
	}
}
