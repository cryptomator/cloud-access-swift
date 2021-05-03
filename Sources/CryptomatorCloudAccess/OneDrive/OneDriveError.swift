//
//  OneDriveError.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 17.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum OneDriveError: Error {
	case invalidURL
	case unexpectedResult
	case inconsistentCache
	case missingItemName
	case unexpectedHTTPStatusCode(code: Int)
	case invalidFileHandle
	case missingFileSize
}
