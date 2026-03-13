//
//  NetworkConnectionError.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.03.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Returns `true` if the given error (or any underlying error) indicates a network connectivity issue.
///
/// Checks for `URLError` codes that indicate the device is offline or cannot reach the host.
/// Recursively unwraps errors stored in `NSUnderlyingErrorKey` to handle SDK-wrapped errors.
func isNetworkConnectionError(_ error: Error) -> Bool {
	if let urlError = error as? URLError {
		return urlError.code.isNetworkConnectionErrorCode
	}
	let nsError = error as NSError
	if nsError.domain == NSURLErrorDomain {
		return URLError.Code(rawValue: nsError.code).isNetworkConnectionErrorCode
	}
	if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
		return isNetworkConnectionError(underlyingError)
	}
	return false
}

private extension URLError.Code {
	var isNetworkConnectionErrorCode: Bool {
		switch self {
		case .notConnectedToInternet,
		     .networkConnectionLost,
		     .cannotFindHost,
		     .cannotConnectToHost,
		     .dnsLookupFailed,
		     .internationalRoamingOff,
		     .dataNotAllowed:
			return true
		default:
			return false
		}
	}
}
