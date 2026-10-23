//
//  GoogleDriveError.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 27.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

enum GoogleDriveError: Error, Equatable {
	case identifierNotFound
	case missingItemName
	case inconsistentCache
	/// Google answered with an unsuccessful status, the first `reason` of the error body and its `message`.
	case apiError(statusCode: Int, reason: String?, message: String?)
	/// A response didn't have the expected content.
	case unexpectedContent

	private static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
	/// The reasons of a 403 for an exceeded rate limit, which a later attempt may pass.
	private static let rateLimitReasons: Set<String> = ["userRateLimitExceeded", "rateLimitExceeded"]

	static func isRetryable(statusCode: Int, reason: String?) -> Bool {
		return retryableStatusCodes.contains(statusCode) || (statusCode == 403 && reason.map(rateLimitReasons.contains) == true)
	}
}
