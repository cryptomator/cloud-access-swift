//
//  BoxError.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 15.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum BoxError: Error, Equatable {
	/// The API answered with a status that the method doesn't map to a `CloudProviderError`, with the `code` and `message` of its error body.
	case apiError(statusCode: Int, code: String?, message: String?)
	/// The file still wasn't ready to download, or the upload still wasn't processed, after the last attempt.
	case fileNotReady
	/// A response or a stored token had content that the library can't use, e.g., a malformed body or an upload URL outside Box.
	case unexpectedContent
	case inconsistentCache
}
