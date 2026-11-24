//
//  URL+Origin.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 17.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

extension URL {
	/// Compares scheme, host and port as written, so a different case or an explicit default port counts as another origin. A missing URL counts as another origin too.
	func hasSameOrigin(as other: URL?) -> Bool {
		guard let other else {
			return false
		}
		return scheme == other.scheme && host == other.host && port == other.port
	}
}
