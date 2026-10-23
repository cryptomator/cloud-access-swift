//
//  PCloudError.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 16.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

enum PCloudError: Error, Equatable {
	/// The pCloud API answered with an error code that the method doesn't map to a `CloudProviderError`.
	case apiError(code: Int, message: String?)
	case unexpectedHTTPStatusCode(code: Int)
	/// The response couldn't be read.
	case unexpectedContent
	case inconsistentCache
	case fileLinkNotFound
}
