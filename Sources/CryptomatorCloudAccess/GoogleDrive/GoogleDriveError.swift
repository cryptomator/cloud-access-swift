//
//  GoogleDriveError.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 27.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum GoogleDriveError: Error, Equatable {
	case identifierNotFound
	case missingItemName
	case inconsistentCache
	case unexpectedError
	/// Google answered with an unsuccessful status, the first `reason` of the error body and its `message`.
	case apiError(statusCode: Int, reason: String?, message: String?)
	/// A response didn't have the expected content.
	case unexpectedContent

	/// The reasons of a 403 for an exceeded rate limit, which a later attempt may pass.
	static let rateLimitReasons: Set<String> = ["userRateLimitExceeded", "rateLimitExceeded"]
}
