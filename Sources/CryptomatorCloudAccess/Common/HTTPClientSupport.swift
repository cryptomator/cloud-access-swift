//
//  HTTPClientSupport.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

enum HTTPClientSupport {
	private static let transientURLErrorCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed]
	private static let failingURLKeys = [NSURLErrorFailingURLErrorKey, NSURLErrorFailingURLStringErrorKey, NSURLErrorFailingURLPeerTrustErrorKey]
	private static let unreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
	private static let unreservedCharactersAndSlash = unreservedCharacters.union(CharacterSet(charactersIn: "/"))

	static func hardened(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
		configuration.httpCookieStorage = HTTPCookieStorage()
		configuration.urlCredentialStorage = nil
		// A listing must never be answered from a cached response, e.g., when an upload checks for an existing item.
		configuration.urlCache = nil
		return configuration
	}

	/// Returns a random wait of up to 2^(retry - 1) seconds, as in the legacy retry mode that botocore and the AWS SDK for Swift use by default. The randomness keeps requests that were throttled together from retrying together.
	static func retryDelay(forRetry retry: Int) -> TimeInterval {
		return TimeInterval.random(in: 0 ... pow(2, TimeInterval(retry - 1)))
	}

	/// Whether the connection couldn't be made, dropped or timed out, including DNS and TLS failures.
	static func isTransient(_ urlError: URLError) -> Bool {
		return transientURLErrorCodes.contains(urlError.code)
	}

	/// Percent-encodes every byte of the UTF-8 form except the unreserved characters, and except `/` if `encodeSlash` is false. A space becomes `%20`.
	static func percentEncoded(_ string: String, encodeSlash: Bool) -> String {
		let allowedCharacters = encodeSlash ? unreservedCharacters : unreservedCharactersAndSlash
		return string.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? string
	}

	/// Joins the parameters as `name=value` pairs separated by `&`, with every name and value percent-encoded, so that `+`, `&` and `=` are escaped.
	static func formEncoded(_ parameters: [(String, String)]) -> String {
		return parameters.map { "\(percentEncoded($0.0, encodeSlash: true))=\(percentEncoded($0.1, encodeSlash: true))" }.joined(separator: "&")
	}

	/// Moves the body of a 2xx response to `stagingURL`, and returns a short body of any other response as data, so that its error can be parsed.
	static func downloadHandler(movingTo stagingURL: URL, maxErrorBodyLength: Int) -> SplitURLSession.DownloadHandler {
		return { location, response in
			if let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) {
				try FileManager.default.moveItem(at: location, to: stagingURL)
				return .file(stagingURL)
			}
			guard let length = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize, length <= maxErrorBodyLength, let body = try? Data(contentsOf: location) else {
				return .none
			}
			return .data(body)
		}
	}

	/// Returns the HTTP response of an attempt. Otherwise it throws the attempt's recorded failure, or else its transport error, sanitized. A cancellation throws `CancellationError`.
	static func httpResponse(of outcome: SplitURLSession.Outcome) throws -> HTTPURLResponse {
		if let recordedFailure = outcome.recordedFailure {
			throw sanitized(recordedFailure)
		}
		if let error = outcome.error {
			throw isCancellationError(error) ? CancellationError() : sanitized(error)
		}
		guard let httpResponse = outcome.response as? HTTPURLResponse else {
			throw URLError(.badServerResponse)
		}
		return httpResponse
	}

	/// Returns the error without the URL of its request, which can be a credential, e.g., a presigned URL. A `URLError` keeps only its code. Any other error keeps its domain, code and the rest of its user info.
	static func sanitized(_ error: Error) -> Error {
		if let urlError = error as? URLError {
			return URLError(urlError.code)
		}
		let nsError = error as NSError
		guard nsError.userInfo.keys.contains(where: { failingURLKeys.contains($0) || $0 == NSUnderlyingErrorKey }) else {
			return error
		}
		var userInfo = nsError.userInfo.filter { !failingURLKeys.contains($0.key) }
		if let underlyingError = userInfo[NSUnderlyingErrorKey] as? Error {
			userInfo[NSUnderlyingErrorKey] = sanitized(underlyingError)
		}
		return NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo)
	}
}
