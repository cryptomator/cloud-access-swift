//
//  ProcessTemporaryDirectoryTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
@testable import CryptomatorCloudAccessCore

/// Records every probed pid. It answers for this process with the given result and probes every other pid for real.
private final class RecordingProbe: Sendable {
	private let ownResult: Int32
	private let probedPIDs = OSAllocatedUnfairLock(initialState: [pid_t]())

	init(ownResult: Int32 = 0) {
		self.ownResult = ownResult
	}

	var pids: [pid_t] {
		probedPIDs.withLock { $0 }
	}

	func probe(_ pid: pid_t) -> Int32 {
		probedPIDs.withLock { $0.append(pid) }
		return pid == getpid() ? ownResult : ProcessTemporaryDirectory.probe(pid)
	}
}

private struct CleanupObservation {
	var deadFolderExists: Bool
	var legacyStagedFileExists: Bool
	var processFolderExists: Bool
}

class ProcessTemporaryDirectoryTests: XCTestCase {
	/// XNU's `PID_MAX` is 99999, so no process has this pid.
	private static let deadPID: pid_t = 100_000

	private var rootURL: URL!
	private var parentURL: URL!
	private var processFoldersURL: URL!
	private var legacyStagingURL: URL!

	override func setUpWithError() throws {
		rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		parentURL = rootURL.appendingPathComponent("CryptomatorCloudAccess", isDirectory: true)
		processFoldersURL = parentURL.appendingPathComponent("pid-v1", isDirectory: true)
		legacyStagingURL = rootURL.appendingPathComponent("CryptomatorCloudAccessStaging", isDirectory: true)
		try FileManager.default.createDirectory(at: processFoldersURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try makeWritable(rootURL)
		try FileManager.default.removeItem(at: rootURL)
	}

	func testSetUp() throws {
		let directory = makeDirectory()

		let processFolderURL = try directory.directoryURL()
		XCTAssertEqual(processFoldersURL.path, processFolderURL.deletingLastPathComponent().path)
		XCTAssertEqual("\(getpid())", processFolderURL.lastPathComponent.split(separator: "-", maxSplits: 1).first.map(String.init))
		XCTAssertNotNil(UUID(uuidString: String(processFolderURL.lastPathComponent.split(separator: "-", maxSplits: 1)[1])))
		XCTAssertEqual(processFolderURL, try directory.directoryURL())
		let firstFolderURL = try directory.makeDirectory()
		let secondFolderURL = try directory.makeDirectory()
		XCTAssertNotEqual(firstFolderURL, secondFolderURL)
		for folderURL in [firstFolderURL, secondFolderURL] {
			XCTAssertEqual(processFolderURL.path, folderURL.deletingLastPathComponent().path)
			XCTAssertTrue(isDirectory(folderURL))
		}
		let fileURL = try directory.makeFileURL()
		XCTAssertEqual(processFolderURL.path, fileURL.deletingLastPathComponent().path)
		XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
	}

	func testDeletesFoldersOfDeadProcesses() throws {
		let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)

		_ = try makeDirectory().directoryURL()

		XCTAssertFalse(FileManager.default.fileExists(atPath: deadFolderURL.path))
	}

	func testKeepsFoldersOfLiveProcesses() throws {
		let otherInstanceFolderURL = try makeDirectory().directoryURL()
		let launchdFolderURL = try makeOwnerFolder(pid: 1)
		let ownPIDFolderURL = try makeOwnerFolder(pid: getpid())

		_ = try makeDirectory().directoryURL()

		for folderURL in [otherInstanceFolderURL, launchdFolderURL, ownPIDFolderURL] {
			XCTAssertTrue(isDirectory(folderURL), folderURL.lastPathComponent)
		}
		XCTAssertTrue(FileManager.default.fileExists(atPath: launchdFolderURL.appendingPathComponent("content").path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: ownPIDFolderURL.appendingPathComponent("content").path))
	}

	/// Probing its own pid gives 0, so only the probe count shows that a folder with the process's pid is never a candidate.
	func testProbesOwnPIDOnlyAsSelfProbe() throws {
		_ = try makeOwnerFolder(pid: getpid())
		_ = try makeOwnerFolder(pid: getpid())
		let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)
		let probe = RecordingProbe()

		_ = try makeDirectory(probe: probe).directoryURL()

		XCTAssertEqual(1, probe.pids.filter { $0 == getpid() }.count)
		XCTAssertFalse(FileManager.default.fileExists(atPath: deadFolderURL.path))
	}

	func testDeletesNothingWhenSelfProbeFails() throws {
		let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)

		for ownResult in [EPERM, ESRCH] {
			let processFolderURL = try makeDirectory(probe: RecordingProbe(ownResult: ownResult)).directoryURL()

			XCTAssertTrue(isDirectory(processFolderURL), "\(ownResult)")
			XCTAssertTrue(isDirectory(deadFolderURL), "\(ownResult)")
		}
	}

	func testKeepsEntriesWithoutStrictName() throws {
		let uuid = UUID().uuidString
		let names = ["0-\(uuid)", "-5-\(uuid)", "+100000-\(uuid)", "abc-\(uuid)", "100000-notauuid", " 100000-\(uuid)", "100000-\(uuid)x", "100000-\u{301}\(uuid)", "100000-\u{200D}\(uuid)"]
		for name in names {
			try FileManager.default.createDirectory(at: processFoldersURL.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
		}
		let fileURL = processFoldersURL.appendingPathComponent("100000-\(UUID().uuidString)", isDirectory: false)
		try Data("content".utf8).write(to: fileURL)
		let targetURL = rootURL.appendingPathComponent("target", isDirectory: true)
		try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)
		try Data("content".utf8).write(to: targetURL.appendingPathComponent("content"))
		let symlinkURL = processFoldersURL.appendingPathComponent("100000-\(UUID().uuidString)", isDirectory: false)
		try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

		_ = try makeDirectory().directoryURL()

		for name in names {
			XCTAssertTrue(isDirectory(processFoldersURL.appendingPathComponent(name, isDirectory: true)), name)
		}
		XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
		XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.appendingPathComponent("content").path))
	}

	func testCleansUpBeforeCreatingProcessFolder() throws {
		let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)
		let legacyStagedFileURL = try makeLegacyStagedFile(age: 25 * 60 * 60)
		let observation = OSAllocatedUnfairLock<CleanupObservation?>(initialState: nil)
		var events = ProcessTemporaryDirectory.Events()
		events.willCreateProcessFolder = { processFolderURL in
			let fileManager = FileManager.default
			let observed = CleanupObservation(deadFolderExists: fileManager.fileExists(atPath: deadFolderURL.path), legacyStagedFileExists: fileManager.fileExists(atPath: legacyStagedFileURL.path), processFolderExists: fileManager.fileExists(atPath: processFolderURL.path))
			observation.withLock { $0 = observed }
		}

		let processFolderURL = try ProcessTemporaryDirectory(parentURL: parentURL, legacyStagingURL: legacyStagingURL, events: events).directoryURL()

		let observed = try XCTUnwrap(observation.withLock { $0 })
		XCTAssertFalse(observed.deadFolderExists)
		XCTAssertFalse(observed.legacyStagedFileExists)
		XCTAssertFalse(observed.processFolderExists)
		XCTAssertTrue(isDirectory(processFolderURL))
	}

	func testRetriesSetUpAfterFailure() throws {
		try FileManager.default.removeItem(at: parentURL)
		try Data().write(to: parentURL)
		let legacyStagedFileURL = try makeLegacyStagedFile(age: 25 * 60 * 60)
		let directory = makeDirectory()

		XCTAssertThrowsError(try directory.directoryURL())
		XCTAssertFalse(FileManager.default.fileExists(atPath: legacyStagedFileURL.path))

		try FileManager.default.removeItem(at: parentURL)
		let processFolderURL = try directory.directoryURL()
		XCTAssertTrue(isDirectory(processFolderURL))
	}

	func testDeletesOldLegacyStagedFilesAndEmptyFolder() throws {
		_ = try makeLegacyStagedFile(age: 25 * 60 * 60)

		_ = try makeDirectory().directoryURL()

		XCTAssertFalse(FileManager.default.fileExists(atPath: legacyStagingURL.path))
	}

	func testKeepsFreshLegacyStagedFiles() throws {
		let legacyStagedFileURL = try makeLegacyStagedFile(age: 60 * 60)

		_ = try makeDirectory().directoryURL()

		XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStagedFileURL.path))
	}

	func testKeepsLegacySubfolders() throws {
		let oldFileURL = try makeLegacyStagedFile(age: 25 * 60 * 60)
		let subfolderURL = legacyStagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: subfolderURL, withIntermediateDirectories: false)
		try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -25 * 60 * 60)], ofItemAtPath: subfolderURL.path)

		_ = try makeDirectory().directoryURL()

		XCTAssertFalse(FileManager.default.fileExists(atPath: oldFileURL.path))
		XCTAssertTrue(isDirectory(subfolderURL))
	}

	func testSweepsOnlyOnce() throws {
		let directory = makeDirectory()
		_ = try directory.directoryURL()
		let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)

		_ = try directory.directoryURL()

		XCTAssertTrue(isDirectory(deadFolderURL))
	}

	func testFailedDeletionIsRetriedLater() throws {
		let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)
		let lockedFolderURL = deadFolderURL.appendingPathComponent("locked", isDirectory: true)
		try FileManager.default.createDirectory(at: lockedFolderURL, withIntermediateDirectories: false)
		try Data("content".utf8).write(to: lockedFolderURL.appendingPathComponent("content"))
		try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedFolderURL.path)

		XCTAssertNoThrow(try makeDirectory().directoryURL())
		XCTAssertTrue(isDirectory(deadFolderURL))

		try makeWritable(rootURL)
		_ = try makeDirectory().directoryURL()
		XCTAssertFalse(FileManager.default.fileExists(atPath: deadFolderURL.path))
	}

	// MARK: - Internal

	private func makeDirectory(probe: RecordingProbe = RecordingProbe()) -> ProcessTemporaryDirectory {
		return ProcessTemporaryDirectory(parentURL: parentURL, legacyStagingURL: legacyStagingURL, probe: { probe.probe($0) })
	}

	private func makeOwnerFolder(pid: pid_t) throws -> URL {
		let folderURL = processFoldersURL.appendingPathComponent("\(pid)-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
		try Data("content".utf8).write(to: folderURL.appendingPathComponent("content"))
		return folderURL
	}

	private func makeLegacyStagedFile(age: TimeInterval) throws -> URL {
		try FileManager.default.createDirectory(at: legacyStagingURL, withIntermediateDirectories: true)
		let fileURL = legacyStagingURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try Data("content".utf8).write(to: fileURL)
		try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: fileURL.path)
		return fileURL
	}

	private func isDirectory(_ url: URL) -> Bool {
		var isDirectory: ObjCBool = false
		return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
	}

	private func makeWritable(_ url: URL) throws {
		guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
			return
		}
		for case let itemURL as URL in enumerator {
			let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
			if values.isDirectory == true, values.isSymbolicLink != true {
				try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: itemURL.path)
			}
		}
	}
}
