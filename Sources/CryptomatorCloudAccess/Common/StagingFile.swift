//
//  StagingFile.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// A file owned by a single operation, which writes its download there and publishes it to the caller's destination only after everything else succeeded.
struct StagingFile: Sendable {
	private static let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("CryptomatorCloudAccessStaging", isDirectory: true)

	/// The URL to write to. No item exists at this URL until the operation creates it.
	let url: URL

	init() throws {
		try FileManager.default.createDirectory(at: StagingFile.directoryURL, withIntermediateDirectories: true)
		self.url = StagingFile.directoryURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
	}

	/**
	 Moves the staged file to the given destination without overwriting an existing item.

	 - Throws: `CloudProviderError.itemAlreadyExists` if an item already exists at `destination`.
	 */
	func publish(to destination: URL) throws {
		do {
			try FileManager.default.moveItem(at: url, to: destination)
		} catch CocoaError.fileWriteFileExists {
			throw CloudProviderError.itemAlreadyExists
		}
	}

	func delete() {
		try? FileManager.default.removeItem(at: url)
	}
}
