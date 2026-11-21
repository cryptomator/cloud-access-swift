//
//  Sequence+Hex.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 19.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

extension Sequence<UInt8> {
	/// The bytes as lowercase hexadecimal digits, two per byte.
	func hexEncodedString(separator: String = "") -> String {
		return map { String(format: "%02x", $0) }.joined(separator: separator)
	}
}
