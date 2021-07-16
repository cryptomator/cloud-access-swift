//
//  GoogleDriveError.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 27.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum GoogleDriveError: Error {
	case identifierNotFound
	case missingItemName
	case unexpectedResultType
	case inconsistentCache
	case unexpectedError
}
