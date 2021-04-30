//
//  CloudItemType.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 24.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

public enum CloudItemType: String, Codable, DatabaseValueConvertible {
	case file
	case folder
	case symlink
	case unknown
}
