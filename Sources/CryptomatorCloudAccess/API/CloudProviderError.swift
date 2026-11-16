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
	/// Thrown by `moveFolder` or `moveFile` once the target is complete and usable, when leftovers remain at the source.
	case moveCompletedWithSourceRemaining
}
