//
//  CloudProvider+VaultFile.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// The largest dir file that the vault decorators read, as cryptofs's `DirectoryIdLoader` does, although a dir ID has 36 characters.
let vaultDirFileMaxLength = 1000

/// The largest shortened-name file that the shortening decorators read, as in cryptofs.
let vaultNameFileMaxLength = 10 * 1024

extension CloudProvider {
	/// - Throws: `VaultFormatError.invalidDirectoryReference` if the file is larger than `vaultDirFileMaxLength`. Other errors unchanged.
	func downloadDirFile(at cloudPath: CloudPath) async throws -> Data {
		return try await downloadSmallFile(at: cloudPath, maxLength: vaultDirFileMaxLength, tooLargeError: .invalidDirectoryReference)
	}

	/// - Throws: `VaultFormatError.invalidNameFile` if the file is larger than `vaultNameFileMaxLength`. Other errors unchanged.
	func downloadNameFile(at cloudPath: CloudPath) async throws -> Data {
		return try await downloadSmallFile(at: cloudPath, maxLength: vaultNameFileMaxLength, tooLargeError: .invalidNameFile)
	}

	/// Reads at most `maxLength + 1` bytes of the downloaded file into memory, so that a large file at the path of a dir file or name file in a shared vault can't exhaust the memory of the File Provider extension.
	private func downloadSmallFile(at cloudPath: CloudPath, maxLength: Int, tooLargeError: VaultFormatError) async throws -> Data {
		let localURL = try ProcessTemporaryDirectory.shared.makeFileURL()
		defer {
			try? FileManager.default.removeItem(at: localURL)
		}
		_ = try await downloadFile(from: cloudPath, to: localURL)
		let fileHandle = try FileHandle(forReadingFrom: localURL)
		defer {
			try? fileHandle.close()
		}
		let data = try fileHandle.read(upToCount: maxLength + 1) ?? Data()
		guard data.count <= maxLength else {
			throw tooLargeError
		}
		return data
	}
}
