//
//  CloudProviderError.swift
//  CryptomatorCloudAccess
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
	case pageTokenInvalid
	case quotaInsufficient
	case unauthorized
	case noInternetConnection
	/// Thrown by `deleteFolder` or `deleteFile` when the cloud refused to delete the item, wholly or in part. The item may still exist, and a later delete can finish it.
	case deletionIncomplete
	/// Thrown by `moveFolder` or `moveFile` once the target is complete and usable, when leftovers remain at the source. Through a vault provider, a folder's leftovers can still refer to the moved folder's directory, so deleting the source, or a folder that contains it, deletes the moved folder's content.
	case moveCompletedWithSourceRemaining
}
