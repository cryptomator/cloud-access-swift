//
//  CrossProcessFileLockTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class CrossProcessFileLockTests {
		private let directoryURL: URL

		init() {
			self.directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("Locks", isDirectory: true)
		}

		deinit {
			removeItemRecordingFailure(at: directoryURL.deletingLastPathComponent())
		}

		/// Two open file descriptions of the same file exclude each other also within one process, so a second lock object stands for another process.
		@Test
		func secondLockTimesOutWhileFirstIsHeld() async throws {
			let holder = try await makeLock().acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))
			defer {
				holder.release()
			}

			await #expect(throws: OAuthTokenStoreError.lockTimeout) { try await makeLock().acquire(timeout: .milliseconds(100), pollInterval: .milliseconds(10)) }
		}

		@Test
		func lockIsAcquiredAfterRelease() async throws {
			let lock = makeLock()
			let holder = try await lock.acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))

			holder.release()
			holder.release()

			let secondHolder = try await makeLock().acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))
			secondHolder.release()
			#expect(FileManager.default.fileExists(atPath: lock.fileURL.path), "The lock file must stay, so that all processes lock the same inode")
		}

		/// The simulator may not report file protection, which the device smoke test covers then.
		@Test
		func lockFileAndDirectoryAreProtectedUntilFirstUserAuthentication() async throws {
			let lock = makeLock()
			let holder = try await lock.acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))
			holder.release()

			for url in [lock.fileURL, directoryURL] {
				let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
				guard let protection else {
					continue
				}
				#expect(protection == .completeUntilFirstUserAuthentication, "\(url.lastPathComponent)")
			}
		}

		private func makeLock() -> CrossProcessFileLock {
			return CrossProcessFileLock(directory: directoryURL, name: "test")
		}
	}
}
