//
//  NetworkConnectionError.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 13.03.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Returns whether the first `URLError` of the underlying error chain has a code that says the device is offline or can't reach the host.
func isNetworkConnectionError(_ error: Error) -> Bool {
	let urlError = underlyingErrorChain(of: error).lazy.compactMap { $0 as? URLError }.first
	return urlError?.code.isNetworkConnectionErrorCode ?? false
}

/// Returns `CloudProviderError.noInternetConnection` for a network connection error, and the error itself otherwise.
func convertingNetworkConnectionError(_ error: Error) -> Error {
	return isNetworkConnectionError(error) ? CloudProviderError.noInternetConnection : error
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
