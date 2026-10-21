//
//  TransientError.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

private let transientURLErrorCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet]

/// The S3 error codes of server errors, throttling and request timeouts.
private let transientS3ErrorCodes: Set<String> = ["InternalError", "ServiceUnavailable", "SlowDown", "RequestTimeout"]

/**
 Checks whether the error is a hiccup of the network or the service that the same test, run again, is expected to pass: a connection problem, a timeout, HTTP 5xx or 429, a failed OAuth token request with such a status, or an eventually consistent provider that didn't catch up in time.

 Wrapped errors are unwrapped through `NSUnderlyingErrorKey` and through the associated values of Swift errors, because SDKs wrap the errors of their requests. Cancellation is never transient.
 */
func isTransientIntegrationError(_ error: Error) -> Bool {
	if isCancellationError(error) {
		return false
	}
	return isTransient(error, depth: 0)
}

private func isTransientHTTPStatusCode(_ statusCode: Int) -> Bool {
	return statusCode == 429 || (500 ..< 600).contains(statusCode)
}

private func isTransient(_ error: Error, depth: Int) -> Bool {
	guard depth < 8 else {
		return false
	}
	if let isTransient = isTransientSwiftError(error) {
		return isTransient
	}
	let nsError = error as NSError
	if isTransientNSError(nsError) {
		return true
	}
	if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error, isTransient(underlyingError, depth: depth + 1) {
		return true
	}
	return Mirror(reflecting: error).children.contains { child in
		guard let wrappedError = child.value as? Error else {
			return false
		}
		return isTransient(wrappedError, depth: depth + 1)
	}
}

/// Classifies the error types of this library, its tests and the SDKs, or returns `nil` for any other error.
private func isTransientSwiftError(_ error: Error) -> Bool? {
	switch error {
	case let urlError as URLError:
		return transientURLErrorCodes.contains(urlError.code)
	case let error as CloudProviderError:
		return error == .noInternetConnection
	case IntegrationTestError.consistencyTimeout:
		return true
	case let MicrosoftGraphAccessTokenProviderMockError.tokenRequestFailed(statusCode):
		return isTransientHTTPStatusCode(statusCode)
	case let MicrosoftGraphError.unexpectedHTTPStatusCode(statusCode):
		return isTransientHTTPStatusCode(statusCode)
	case let URLSessionError.httpError(underlyingError, statusCode):
		return isTransientHTTPStatusCode(statusCode) || underlyingError.map(isTransientIntegrationError) ?? false
	case DropboxError.tooManyWriteOperations, DropboxError.rateLimitError, DropboxError.internalServerError, DropboxError.clientError:
		return true
	case let BoxError.apiError(statusCode, _, _), let GoogleDriveError.apiError(statusCode, _, _), let OAuthTokenEndpointError.unsuccessfulResponse(statusCode, _, _):
		return isTransientHTTPStatusCode(statusCode)
	case let error as S3Error:
		return error.code.map(transientS3ErrorCodes.contains) ?? false || isTransientHTTPStatusCode(error.statusCode)
	default:
		return (error as? PCloudError).map(isTransientPCloudError)
	}
}

private func isTransientPCloudError(_ error: PCloudError) -> Bool {
	switch error {
	case let .apiError(code, _):
		// Too many login attempts, too many actions, or an internal error.
		return code == 4000 || code == 4010 || (5000 ..< 6000).contains(code)
	case let .unexpectedHTTPStatusCode(statusCode):
		return isTransientHTTPStatusCode(statusCode)
	default:
		return false
	}
}

private func isTransientNSError(_ error: NSError) -> Bool {
	return error.domain == NSURLErrorDomain && transientURLErrorCodes.contains(URLError.Code(rawValue: error.code))
}
