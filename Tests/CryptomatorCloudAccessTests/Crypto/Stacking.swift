//
//  Stacking.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 17.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Testing

/// Whether a vault decorator of a test sits directly on the vault mock or on a shortening decorator in between.
enum Stacking: CaseIterable, CustomTestStringConvertible {
	case plain
	case shortening

	var testDescription: String {
		return "\(self)"
	}
}
