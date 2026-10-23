//
//  MicrosoftGraphError.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 17.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

enum MicrosoftGraphError: Error {
	case invalidURL
	case inconsistentCache
	case missingItemName
	case unexpectedHTTPStatusCode(code: Int)
	case missingFileSize
}
