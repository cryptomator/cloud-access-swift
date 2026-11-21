//
//  ProcessTemporaryDirectory.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

/**
 Holds the temporary items of the library in one folder per process, `pid-v1/<pid>-<UUID>/` in the parent folder.

 A process that iOS kills runs neither `deinit` nor `defer`, so its items stay behind. Before a process creates its own folder, it therefore deletes the folders of processes that no longer exist, i.e., whose pid `kill(pid, 0)` answers with `ESRCH`. The kernel looks a pid up before any permission check, so a live, suspended or zombie process never gives `ESRCH`. A folder is kept for any other result. No process folder is deleted if the process can't probe itself, e.g., because a sandbox filters `kill`.
 */
final class ProcessTemporaryDirectory: Sendable {
	/// Lets tests observe the order of the setup.
	struct Events: Sendable {
		/// Runs after the cleanup.
		var willCreateProcessFolder: @Sendable (URL) -> Void = { _ in }
	}

	static let shared = ProcessTemporaryDirectory(parentURL: FileManager.default.temporaryDirectory.appendingPathComponent("CryptomatorCloudAccess", isDirectory: true), legacyStagingURL: FileManager.default.temporaryDirectory.appendingPathComponent("CryptomatorCloudAccessStaging", isDirectory: true))

	private static let legacyStagedFileMaxAge: TimeInterval = 24 * 60 * 60

	private let processFoldersURL: URL
	private let legacyStagingURL: URL
	private let probe: @Sendable (pid_t) -> Int32
	private let events: Events
	private let processFolderURL = OSAllocatedUnfairLock<URL?>(initialState: nil)

	/**
	 - Parameter legacyStagingURL: The folder in which earlier versions staged downloads for all processes.
	 - Parameter probe: Returns 0 if a process has the pid, or else the `errno` that `kill(pid, 0)` would set. Tests inject one that simulates a filtered `kill`.
	 */
	init(parentURL: URL, legacyStagingURL: URL, probe: @escaping @Sendable (pid_t) -> Int32 = { ProcessTemporaryDirectory.probe($0) }, events: Events = Events()) {
		self.processFoldersURL = parentURL.appendingPathComponent("pid-v1", isDirectory: true)
		self.legacyStagingURL = legacyStagingURL
		self.probe = probe
		self.events = events
	}

	static func probe(_ pid: pid_t) -> Int32 {
		return kill(pid, 0) == 0 ? 0 : errno
	}

	/// Returns the folder of this process. Until one was created, each call cleans up and then tries to create it.
	func directoryURL() throws -> URL {
		return try processFolderURL.withLockUnchecked { processFolderURL in
			if let processFolderURL {
				return processFolderURL
			}
			let url = try setUp()
			processFolderURL = url
			return url
		}
	}

	/// Creates a new folder in the folder of this process. Its owner deletes it.
	func makeDirectory() throws -> URL {
		let url = try directoryURL().appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	/// Returns a new file URL in the folder of this process, at which no item exists yet. Its owner deletes the file.
	func makeFileURL() throws -> URL {
		return try directoryURL().appendingPathComponent(UUID().uuidString, isDirectory: false)
	}

	// MARK: - Setup

	/// Cleans up before allocating anything, so that a disk full of leftovers is reclaimed first.
	private func setUp() throws -> URL {
		removeLegacyStagedFiles()
		sweepProcessFolders()
		let url = processFoldersURL.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
		events.willCreateProcessFolder(url)
		try FileManager.default.createDirectory(at: processFoldersURL, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
		CloudAccessDDLogDebug("ProcessTemporaryDirectory: Created \(url.lastPathComponent)")
		return url
	}

	/// Deletes the staged files that are untouched for a day, and then the folder if it is empty. A younger file may still be written by a process of an earlier version.
	private func removeLegacyStagedFiles() {
		let cutoff = Date(timeIntervalSinceNow: -ProcessTemporaryDirectory.legacyStagedFileMaxAge)
		removeEntries(of: legacyStagingURL, description: "the legacy staging folder", keys: [.isRegularFileKey, .contentModificationDateKey]) { _, values in
			guard values.isRegularFile == true, let modificationDate = values.contentModificationDate else {
				return false
			}
			return modificationDate < cutoff
		}
		// Fails without harm if the folder is missing or isn't empty.
		_ = rmdir(legacyStagingURL.path)
	}

	private func sweepProcessFolders() {
		let ownPID = getpid()
		let selfProbeResult = probe(ownPID)
		guard selfProbeResult == 0 else {
			CloudAccessDDLogDebug("ProcessTemporaryDirectory: Self-probe failed with errno \(selfProbeResult), deleting no process folders")
			return
		}
		CloudAccessDDLogDebug("ProcessTemporaryDirectory: Self-probe succeeded")
		removeEntries(of: processFoldersURL, description: "the process folders", keys: [.isDirectoryKey, .isSymbolicLinkKey]) { url, values in
			// Another instance in this process may own a folder with its pid.
			guard values.isDirectory == true, values.isSymbolicLink != true, let pid = ProcessTemporaryDirectory.ownerPID(ofFolderNamed: url.lastPathComponent), pid != ownPID else {
				return false
			}
			return probe(pid) == ESRCH
		}
	}

	/// Deletes each entry of the folder for which `shouldRemove` returns true, and logs a failed listing or deletion. A missing folder holds nothing to delete.
	private func removeEntries(of folderURL: URL, description: String, keys: Set<URLResourceKey>, where shouldRemove: (URL, URLResourceValues) -> Bool) {
		let urls: [URL]
		do {
			urls = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: Array(keys))
		} catch CocoaError.fileReadNoSuchFile {
			return
		} catch {
			CloudAccessDDLogDebug("ProcessTemporaryDirectory: Listing \(description) failed with \(error)")
			return
		}
		for url in urls {
			guard let values = try? url.resourceValues(forKeys: keys), shouldRemove(url, values) else {
				continue
			}
			do {
				try FileManager.default.removeItem(at: url)
				CloudAccessDDLogDebug("ProcessTemporaryDirectory: Deleted \(url.lastPathComponent) from \(description)")
			} catch {
				CloudAccessDDLogDebug("ProcessTemporaryDirectory: Deleting \(url.lastPathComponent) from \(description) failed with \(error)")
			}
		}
	}

	/// Returns the pid of a folder named `<pid>-<UUID>`, where the pid consists of ASCII digits only and is positive. The name is split by byte, because stepping past the `-` by `Character` would also skip a combining mark after it.
	private static func ownerPID(ofFolderNamed name: String) -> pid_t? {
		let utf8 = name.utf8
		guard let separatorIndex = utf8.firstIndex(of: UInt8(ascii: "-")) else {
			return nil
		}
		let pidDigits = utf8[..<separatorIndex]
		let uuidString = String(Substring(utf8[utf8.index(after: separatorIndex)...]))
		guard pidDigits.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }), let pid = pid_t(String(Substring(pidDigits))), pid > 0, UUID(uuidString: uuidString) != nil else {
			return nil
		}
		return pid
	}
}
