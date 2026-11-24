//
//  CloudProviderError.swift
//  CryptomatorCloudAccessCore
//
//  Created by Philipp Schmid on 23.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum CloudProviderError: Error {
	case itemNotFound
	case itemAlreadyExists
	case itemTypeMismatch
	case parentFolderDoesNotExist
	/// Thrown before any request for a cloud path that is relative or has an empty, `.` or `..` component below the root. The library resolves such a path to no item, so the caller has to correct it rather than retry. The local file system provider also throws it for a path that contains a NUL character, which no file name holds. It isn't `itemNotFound`, because `checkForItemExistence` and the `…IfExisting` helpers would take that for a missing item, although a file system or server would resolve the path to an item that may exist.
	case invalidPath
	case pageTokenInvalid
	case quotaInsufficient
	case unauthorized
	case noInternetConnection
	/// Thrown by `deleteFolder` or `deleteFile` when the cloud refused to delete the item, wholly or in part. The item may still exist, and a later delete can finish it.
	case deletionIncomplete
	/// Thrown by `moveFolder` or `moveFile` once the target is complete and usable, when leftovers remain at the source. Through a vault provider, a folder's leftovers can still refer to the moved folder's directory, so deleting the source, or a folder that contains it, deletes the moved folder's content.
	case moveCompletedWithSourceRemaining
}
