//
//  IntegrationTestError.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 13.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

enum IntegrationTestError: Error {
	case cloudProviderInitError
	case missingDirectoryEnumerator
	case consistencyTimeout
	case oneTimeSetUpTimeout
	case setUpTimeout
}
