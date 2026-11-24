//
//  PCloudError.swift
//  CryptomatorCloudAccessCore
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
	/// A key, the result, an element, the folder's fields or the nesting of a folder listing exceeds what `PCloudListingReader` holds in memory.
	case listingTooLarge
	case inconsistentCache
	case fileLinkNotFound

	/// Describes an error for the log, leaving out an API error's message, which a content host could fill with the path of the file link that it refused.
	static func descriptionWithoutMessage(of error: Error) -> String {
		guard case let PCloudError.apiError(code, _) = error else {
			return "\(error)"
		}
		return "pCloud API error \(code)"
	}
}
