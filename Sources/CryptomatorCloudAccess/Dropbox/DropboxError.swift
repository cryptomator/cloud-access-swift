//
//  DropboxError.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 03.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum DropboxError: Error, Equatable {
	/// The API answered with a status that the method doesn't map to a `CloudProviderError`. The summary is the body's `error_summary`, e.g., `path/malformed_path/..`, or the first line of a plain-text 400 body.
	case apiError(statusCode: Int, summary: String?)
	/// A response had content that the library can't use, e.g., a malformed body or an offset that the upload can't continue from. It is also thrown if the local file got shorter during an upload.
	case unexpectedContent

	/// A 429, a 5xx, or a 409 whose `error_summary` has the tag `too_many_write_operations` at any level. The summary is read only for a 409, so that a successful body isn't decoded for it.
	static func isRetryable(statusCode: Int, summary: @autoclosure () -> String?) -> Bool {
		switch statusCode {
		case 409:
			return DropboxErrorResponse.tags(of: summary()).contains("too_many_write_operations")
		case 429, 500...:
			return true
		default:
			return false
		}
	}
}
