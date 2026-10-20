//
//  CrossProcessFileLock.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

/**
 An exclusive `flock` on one lock file. Each acquisition opens its own file descriptor, so a holder excludes the other holders of the file in this process as well as in other processes, e.g., the app and its extensions in an App Group container.

 The file is never deleted, so that all processes lock the same inode. A process that dies releases its lock.
 */
final class CrossProcessFileLock: Sendable {
	/// Lets tests observe a waiter without depending on timing.
	struct Events: Sendable {
		/// Runs whenever an attempt finds the lock held.
		var contention: @Sendable () -> Void = {}
		var acquired: @Sendable () -> Void = {}
	}

	/// A held lock. It is released when the holder is released or deallocated.
	final class Holder: Sendable {
		private let fileDescriptor: OSAllocatedUnfairLock<Int32?>

		fileprivate init(fileDescriptor: Int32) {
			self.fileDescriptor = OSAllocatedUnfairLock(initialState: fileDescriptor)
		}

		deinit {
			release()
		}

		/// Closes the file descriptor, which releases the lock. Further calls do nothing.
		func release() {
			let fileDescriptor = fileDescriptor.withLock { fileDescriptor in
				defer { fileDescriptor = nil }
				return fileDescriptor
			}
			if let fileDescriptor {
				close(fileDescriptor)
			}
		}
	}

	/// A process whose default protection is `complete` would otherwise create a lock file that background work can't open on a locked device.
	private static let protection = [FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]

	let fileURL: URL
	private let directory: URL
	private let events: Events

	init(directory: URL, name: String, events: Events = Events()) {
		self.directory = directory
		self.fileURL = directory.appendingPathComponent("\(name).lock", isDirectory: false)
		self.events = events
	}

	/**
	 Waits until this process holds the lock.

	 - Throws: `OAuthTokenStoreError.lockTimeout` if another holder kept the lock for `timeout`, a file system error if the lock file can't be created, opened or locked, and `CancellationError` if the task was cancelled while waiting.
	 */
	func acquire(timeout: Duration, pollInterval: Duration) async throws -> Holder {
		let fileDescriptor = try openLockFile()
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: timeout)
		do {
			while true {
				if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
					events.acquired()
					return Holder(fileDescriptor: fileDescriptor)
				}
				let code = errno
				guard code == EWOULDBLOCK else {
					throw CrossProcessFileLock.posixError(code)
				}
				events.contention()
				guard clock.now < deadline else {
					throw OAuthTokenStoreError.lockTimeout
				}
				try await Task.sleep(for: pollInterval)
			}
		} catch {
			close(fileDescriptor)
			throw error
		}
	}

	private func openLockFile() throws -> Int32 {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: CrossProcessFileLock.protection)
		let fileDescriptor = open(fileURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
		guard fileDescriptor >= 0 else {
			throw CrossProcessFileLock.posixError(errno)
		}
		do {
			try FileManager.default.setAttributes(CrossProcessFileLock.protection, ofItemAtPath: fileURL.path)
		} catch {
			close(fileDescriptor)
			throw error
		}
		return fileDescriptor
	}

	private static func posixError(_ code: Int32) -> POSIXError {
		return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
	}
}
