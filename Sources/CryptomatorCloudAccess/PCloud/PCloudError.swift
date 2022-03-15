//
//  PCloudError.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 16.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum PCloudError: Error {
	case unexpectedContent
	case inconsistentCache
	case fileLinkNotFound
}
