//
//  ProcessTemporaryDirectoryTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
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

extension UnitTests {
	final class ProcessTemporaryDirectoryTests {
		/// XNU's `PID_MAX` is 99999, so no process has this pid.
		private static let deadPID: pid_t = 100_000

		private let rootURL: URL
		private let parentURL: URL
		private let processFoldersURL: URL
		private let legacyStagingURL: URL

		init() throws {
			let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			let parentURL = rootURL.appendingPathComponent("CryptomatorCloudAccess", isDirectory: true)
			let processFoldersURL = parentURL.appendingPathComponent("pid-v1", isDirectory: true)
			self.rootURL = rootURL
			self.parentURL = parentURL
			self.processFoldersURL = processFoldersURL
			self.legacyStagingURL = rootURL.appendingPathComponent("CryptomatorCloudAccessStaging", isDirectory: true)
			try FileManager.default.createDirectory(at: processFoldersURL, withIntermediateDirectories: true)
		}

		deinit {
			do {
				try makeWritable(rootURL)
			} catch {
				Issue.record(error)
			}
			removeItemRecordingFailure(at: rootURL)
		}

		@Test
		func setUp() throws {
			let directory = makeDirectory()

			let processFolderURL = try directory.directoryURL()
			#expect(processFoldersURL.path == processFolderURL.deletingLastPathComponent().path)
			#expect(processFolderURL.lastPathComponent.split(separator: "-", maxSplits: 1).first.map(String.init) == "\(getpid())")
			#expect(UUID(uuidString: String(processFolderURL.lastPathComponent.split(separator: "-", maxSplits: 1)[1])) != nil)
			#expect(try processFolderURL == directory.directoryURL())
			let firstFolderURL = try directory.makeDirectory()
			let secondFolderURL = try directory.makeDirectory()
			#expect(firstFolderURL != secondFolderURL)
			for folderURL in [firstFolderURL, secondFolderURL] {
				#expect(processFolderURL.path == folderURL.deletingLastPathComponent().path)
				#expect(isDirectory(folderURL))
			}
			let fileURL = try directory.makeFileURL()
			#expect(processFolderURL.path == fileURL.deletingLastPathComponent().path)
			#expect(!FileManager.default.fileExists(atPath: fileURL.path))
		}

		@Test
		func deletesFoldersOfDeadProcesses() throws {
			let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)

			_ = try makeDirectory().directoryURL()

			#expect(!FileManager.default.fileExists(atPath: deadFolderURL.path))
		}

		@Test
		func keepsFoldersOfLiveProcesses() throws {
			let otherInstanceFolderURL = try makeDirectory().directoryURL()
			let launchdFolderURL = try makeOwnerFolder(pid: 1)
			let ownPIDFolderURL = try makeOwnerFolder(pid: getpid())

			_ = try makeDirectory().directoryURL()

			for folderURL in [otherInstanceFolderURL, launchdFolderURL, ownPIDFolderURL] {
				#expect(isDirectory(folderURL), "\(folderURL.lastPathComponent)")
			}
			#expect(FileManager.default.fileExists(atPath: launchdFolderURL.appendingPathComponent("content").path))
			#expect(FileManager.default.fileExists(atPath: ownPIDFolderURL.appendingPathComponent("content").path))
		}

		/// Probing its own pid gives 0, so only the probe count shows that a folder with the process's pid is never a candidate.
		@Test
		func probesOwnPIDOnlyAsSelfProbe() throws {
			_ = try makeOwnerFolder(pid: getpid())
			_ = try makeOwnerFolder(pid: getpid())
			let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)
			let probe = RecordingProbe()

			_ = try makeDirectory(probe: probe).directoryURL()

			#expect(probe.pids.filter { $0 == getpid() }.count == 1)
			#expect(!FileManager.default.fileExists(atPath: deadFolderURL.path))
		}

		@Test
		func deletesNothingWhenSelfProbeFails() throws {
			let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)

			for ownResult in [EPERM, ESRCH] {
				let processFolderURL = try makeDirectory(probe: RecordingProbe(ownResult: ownResult)).directoryURL()

				#expect(isDirectory(processFolderURL), "\(ownResult)")
				#expect(isDirectory(deadFolderURL), "\(ownResult)")
			}
		}

		@Test
		func keepsEntriesWithoutStrictName() throws {
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
				#expect(isDirectory(processFoldersURL.appendingPathComponent(name, isDirectory: true)), "\(name)")
			}
			#expect(FileManager.default.fileExists(atPath: fileURL.path))
			#expect((try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path)) != nil)
			#expect(FileManager.default.fileExists(atPath: targetURL.appendingPathComponent("content").path))
		}

		@Test
		func cleansUpBeforeCreatingProcessFolder() throws {
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

			let observed = try #require(observation.withLock { $0 })
			#expect(!observed.deadFolderExists)
			#expect(!observed.legacyStagedFileExists)
			#expect(!observed.processFolderExists)
			#expect(isDirectory(processFolderURL))
		}

		@Test
		func retriesSetUpAfterFailure() throws {
			try FileManager.default.removeItem(at: parentURL)
			try Data().write(to: parentURL)
			let legacyStagedFileURL = try makeLegacyStagedFile(age: 25 * 60 * 60)
			let directory = makeDirectory()

			#expect(throws: (any Error).self) { try directory.directoryURL() }
			#expect(!FileManager.default.fileExists(atPath: legacyStagedFileURL.path))

			try FileManager.default.removeItem(at: parentURL)
			let processFolderURL = try directory.directoryURL()
			#expect(isDirectory(processFolderURL))
		}

		@Test
		func deletesOldLegacyStagedFilesAndEmptyFolder() throws {
			_ = try makeLegacyStagedFile(age: 25 * 60 * 60)

			_ = try makeDirectory().directoryURL()

			#expect(!FileManager.default.fileExists(atPath: legacyStagingURL.path))
		}

		@Test
		func keepsFreshLegacyStagedFiles() throws {
			let legacyStagedFileURL = try makeLegacyStagedFile(age: 60 * 60)

			_ = try makeDirectory().directoryURL()

			#expect(FileManager.default.fileExists(atPath: legacyStagedFileURL.path))
		}

		@Test
		func keepsLegacySubfolders() throws {
			let oldFileURL = try makeLegacyStagedFile(age: 25 * 60 * 60)
			let subfolderURL = legacyStagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: subfolderURL, withIntermediateDirectories: false)
			try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -25 * 60 * 60)], ofItemAtPath: subfolderURL.path)

			_ = try makeDirectory().directoryURL()

			#expect(!FileManager.default.fileExists(atPath: oldFileURL.path))
			#expect(isDirectory(subfolderURL))
		}

		@Test
		func sweepsOnlyOnce() throws {
			let directory = makeDirectory()
			_ = try directory.directoryURL()
			let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)

			_ = try directory.directoryURL()

			#expect(isDirectory(deadFolderURL))
		}

		@Test
		func failedDeletionIsRetriedLater() throws {
			let deadFolderURL = try makeOwnerFolder(pid: ProcessTemporaryDirectoryTests.deadPID)
			let lockedFolderURL = deadFolderURL.appendingPathComponent("locked", isDirectory: true)
			try FileManager.default.createDirectory(at: lockedFolderURL, withIntermediateDirectories: false)
			try Data("content".utf8).write(to: lockedFolderURL.appendingPathComponent("content"))
			try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedFolderURL.path)

			#expect(throws: Never.self) { try makeDirectory().directoryURL() }
			#expect(isDirectory(deadFolderURL))

			try makeWritable(rootURL)
			_ = try makeDirectory().directoryURL()
			#expect(!FileManager.default.fileExists(atPath: deadFolderURL.path))
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
}
