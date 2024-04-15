//
//  BoxError.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 15.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum BoxError: Error {
	case unexpectedContent
	case inconsistentCache
	case fileLinkNotFound
}
