//
//  IntegrationTestError.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 13.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Foundation

enum IntegrationTestError: Error, Equatable {
	case consistencyTimeout
	case itemNotVisible(CloudPath)
	case fixtureTimeout(Duration)
	case budgetExceeded(Duration)
}
