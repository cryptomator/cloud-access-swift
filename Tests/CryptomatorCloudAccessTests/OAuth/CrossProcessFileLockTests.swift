//
//  CrossProcessFileLockTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class CrossProcessFileLockTests: XCTestCase {
	private var directoryURL: URL!

	override func setUpWithError() throws {
		directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("Locks", isDirectory: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directoryURL.deletingLastPathComponent())
	}

	/// Two open file descriptions of the same file exclude each other also within one process, so a second lock object stands for another process.
	func testSecondLockTimesOutWhileFirstIsHeld() async throws {
		let holder = try await makeLock().acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))
		defer {
			holder.release()
		}

		await XCTAssertThrowsErrorAsync(try await makeLock().acquire(timeout: .milliseconds(100), pollInterval: .milliseconds(10))) { error in
			XCTAssertEqual(.lockTimeout, error as? OAuthTokenStoreError)
		}
	}

	func testLockIsAcquiredAfterRelease() async throws {
		let lock = makeLock()
		let holder = try await lock.acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))

		holder.release()
		holder.release()

		let secondHolder = try await makeLock().acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))
		secondHolder.release()
		XCTAssertTrue(FileManager.default.fileExists(atPath: lock.fileURL.path), "The lock file must stay, so that all processes lock the same inode")
	}

	/// The simulator may not report file protection, which the device smoke test covers then.
	func testLockFileAndDirectoryAreProtectedUntilFirstUserAuthentication() async throws {
		let lock = makeLock()
		let holder = try await lock.acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))
		holder.release()

		for url in try [lock.fileURL, XCTUnwrap(directoryURL)] {
			let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
			guard let protection else {
				continue
			}
			XCTAssertEqual(.completeUntilFirstUserAuthentication, protection, url.lastPathComponent)
		}
	}

	private func makeLock() -> CrossProcessFileLock {
		return CrossProcessFileLock(directory: directoryURL, name: "test")
	}
}
