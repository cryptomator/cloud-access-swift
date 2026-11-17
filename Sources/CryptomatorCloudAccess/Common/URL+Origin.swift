//
//  URL+Origin.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 17.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

extension URL {
	/// Compares scheme, host and port as written, so a different case or an explicit default port counts as another origin.
	func hasSameOrigin(as other: URL) -> Bool {
		return scheme == other.scheme && host == other.host && port == other.port
	}
}
