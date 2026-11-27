//
//  LocalUploadFile.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 17.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// The local file of an upload. A symbolic link is followed, so its target's content is uploaded.
struct LocalUploadFile: Sendable {
	/// The URL to read from: the caller's URL, or the resolved target if the caller's URL is a symbolic link.
	let url: URL
	let size: Int64

	/**
	 - Throws:
	   - `CloudProviderError.itemNotFound` if no item exists at `localURL`, or if a symbolic link there points to a missing target.
	   - `CloudProviderError.itemTypeMismatch` if the item at `localURL`, or the target of a symbolic link there, is no regular file.
	   - `CocoaError(.fileReadNoPermission)` if the item or a folder on its path can't be read.
	   - `POSIXError` for any other failure, e.g., `ELOOP` for a loop of symbolic links.
	 */
	init(_ localURL: URL) throws {
		var status = stat()
		// `.path` drops a trailing slash, with which `lstat` would follow a symbolic link.
		guard lstat(localURL.path, &status) == 0 else {
			throw LocalUploadFile.error(forErrno: errno)
		}
		if (status.st_mode & S_IFMT) == S_IFLNK {
			guard let resolvedPath = realpath(localURL.path, nil) else {
				throw LocalUploadFile.error(forErrno: errno)
			}
			defer { free(resolvedPath) }
			guard stat(resolvedPath, &status) == 0 else {
				throw LocalUploadFile.error(forErrno: errno)
			}
			self.url = URL(filePath: String(cString: resolvedPath), directoryHint: .notDirectory)
		} else {
			self.url = localURL
		}
		guard (status.st_mode & S_IFMT) == S_IFREG else {
			throw CloudProviderError.itemTypeMismatch
		}
		self.size = status.st_size
	}

	private static func error(forErrno code: Int32) -> Error {
		let posixError = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
		switch code {
		case ENOENT, ENOTDIR:
			return CloudProviderError.itemNotFound
		case EACCES, EPERM:
			return CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: posixError])
		default:
			return posixError
		}
	}
}
