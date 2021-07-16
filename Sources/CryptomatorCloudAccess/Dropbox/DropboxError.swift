//
//  DropboxError.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 03.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum DropboxError: Error {
	case unexpectedRouteError
	case missingResult
	case unexpectedResult
	case tooManyWriteOperations
	case asyncPollError

	case httpError
	case badInputError
	case authError
	case accessError
	case pathRootError
	case rateLimitError(retryAfter: Int)
	case internalServerError
	case clientError
	case unexpectedError
}
