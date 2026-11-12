//
//  CloudPath+DatabaseValueConvertible.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 19.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

extension CloudPath: DatabaseValueConvertible {
	public var databaseValue: DatabaseValue {
		path.databaseValue
	}

	public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CloudPath? {
		guard case let .string(string) = dbValue.storage else {
			return nil
		}
		return self.init(string)
	}
}
