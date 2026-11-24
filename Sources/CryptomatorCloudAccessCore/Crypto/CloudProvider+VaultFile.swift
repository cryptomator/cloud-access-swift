//
//  CloudProvider+VaultFile.swift
//  CryptomatorCloudAccessCore
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
	/**
	 - Parameter refusingAlias: Whether to refuse a file that the download reached through an alias (`CloudItemMetadata.isAlias`). The dir ID read through an alias is its target's, so a delete would follow a directory that the path doesn't own.
	 - Throws: `VaultFormatError.invalidDirectoryReference` if the file is larger than `vaultDirFileMaxLength` or refused as an alias. Other errors unchanged.
	 */
	func downloadDirFile(at cloudPath: CloudPath, refusingAlias: Bool) async throws -> Data {
		let (data, metadata) = try await downloadSmallFile(at: cloudPath, maxLength: vaultDirFileMaxLength, tooLargeError: .invalidDirectoryReference)
		if refusingAlias, metadata.isAlias {
			throw VaultFormatError.invalidDirectoryReference
		}
		return data
	}

	/// - Throws: `VaultFormatError.invalidNameFile` if the file is larger than `vaultNameFileMaxLength`. Other errors unchanged.
	func downloadNameFile(at cloudPath: CloudPath) async throws -> Data {
		return try await downloadSmallFile(at: cloudPath, maxLength: vaultNameFileMaxLength, tooLargeError: .invalidNameFile).data
	}

	/// Reads at most `maxLength + 1` bytes of the downloaded file into memory, so that a large file at the path of a dir file or name file in a shared vault can't exhaust the memory of the File Provider extension.
	private func downloadSmallFile(at cloudPath: CloudPath, maxLength: Int, tooLargeError: VaultFormatError) async throws -> (data: Data, metadata: CloudItemMetadata) {
		let localURL = try ProcessTemporaryDirectory.shared.makeFileURL()
		defer {
			try? FileManager.default.removeItem(at: localURL)
		}
		let metadata = try await downloadFile(from: cloudPath, to: localURL)
		let fileHandle = try FileHandle(forReadingFrom: localURL)
		defer {
			try? fileHandle.close()
		}
		let data = try fileHandle.read(upToCount: maxLength + 1) ?? Data()
		guard data.count <= maxLength else {
			throw tooLargeError
		}
		return (data, metadata)
	}
}
