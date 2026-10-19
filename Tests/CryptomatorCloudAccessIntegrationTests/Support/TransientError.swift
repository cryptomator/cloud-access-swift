//
//  TransientError.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import BoxSdkGen
import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

private let transientURLErrorCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet]

/// The error domains whose error codes are HTTP status codes: GTLR, GTMSessionFetcher and AppAuth's `OIDHTTPErrorDomain`.
private let httpStatusErrorDomains: Set<String> = ["com.google.GTLRErrorObjectDomain", "com.google.HTTPStatus", "org.openid.appauth.remote-http"]

/// The S3 error codes of server errors, throttling and request timeouts.
private let transientS3ErrorCodes: Set<String> = ["InternalError", "ServiceUnavailable", "SlowDown", "RequestTimeout"]

/// The case names of pCloud's generic `CallError` that a retry can heal.
private let transientPCloudCallErrorCases: Set<String> = ["rateLimitError", "serverInternalError"]

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
	let mirror = Mirror(reflecting: error)
	if String(describing: type(of: error)).hasPrefix("CallError<"), transientPCloudCallErrorCases.contains(mirror.children.first?.label ?? "\(error)") {
		return true
	}
	return mirror.children.contains { child in
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
	case let error as BoxAPIError:
		return isTransientHTTPStatusCode(error.responseInfo.statusCode)
	case let error as S3Error:
		return error.code.map(transientS3ErrorCodes.contains) ?? false || isTransientHTTPStatusCode(error.statusCode)
	default:
		return nil
	}
}

private func isTransientNSError(_ error: NSError) -> Bool {
	if error.domain == NSURLErrorDomain {
		return transientURLErrorCodes.contains(URLError.Code(rawValue: error.code))
	}
	if httpStatusErrorDomains.contains(error.domain) {
		return isTransientHTTPStatusCode(error.code)
	}
	return isAppAuthServerErrorWithTransientStatus(error)
}

/// AppAuth reports a failed token request as `OIDErrorCodeServerError` whose description carries the HTTP status, e.g. "Non-200 HTTP response (500) making token request to '…'".
private func isAppAuthServerErrorWithTransientStatus(_ error: NSError) -> Bool {
	let serverErrorCode = -6
	guard error.domain == "org.openid.appauth.general", error.code == serverErrorCode else {
		return false
	}
	let description = error.userInfo[NSLocalizedDescriptionKey] as? String ?? ""
	guard let match = description.firstMatch(of: /HTTP response \((\d{3})\)/), let statusCode = Int(match.1) else {
		return false
	}
	return isTransientHTTPStatusCode(statusCode)
}
