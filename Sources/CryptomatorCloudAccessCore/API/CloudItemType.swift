//
//  CloudItemType.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 24.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

public enum CloudItemType: String, Codable, DatabaseValueConvertible, Sendable {
	case file
	case folder
	case symlink
	case unknown
}

extension CloudItemType {
	/// Whether an operation on items of `type` accepts an item of this type. A folder operation accepts a folder, and a file operation a file or a symbolic link, so an `unknown` item fits neither.
	func isTaken(byOperationOn type: CloudItemType) -> Bool {
		return type == .folder ? self == .folder : self == .file || self == .symlink
	}
}
