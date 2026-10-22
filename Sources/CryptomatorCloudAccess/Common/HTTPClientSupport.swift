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
	static let maxRetryDelay: TimeInterval = 60
	/// The length of the chunks in which a file is copied into a temporary file.
	static let temporaryFileBufferLength = 64 * 1024

	static func hardened(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
		configuration.httpCookieStorage = HTTPCookieStorage()
		configuration.urlCredentialStorage = nil
		// A listing must never be answered from a cached response, e.g., when an upload checks for an existing item.
		configuration.urlCache = nil
		return configuration
	}

	/// Returns a hardened background configuration whose files an app extension can share with the app through `sharedContainerIdentifier`.
	static func hardenedBackground(identifier: String, sharedContainerIdentifier: String?) -> URLSessionConfiguration {
		let configuration = hardened(.background(withIdentifier: identifier))
		configuration.sharedContainerIdentifier = sharedContainerIdentifier
		return configuration
	}

	/// Returns a hardened configuration for the requests of an OAuth token endpoint, whose timeouts bound how long a refresh holds the token lock.
	static func tokenEndpointConfiguration() -> URLSessionConfiguration {
		let configuration = hardened(.default)
		configuration.timeoutIntervalForRequest = 15
		configuration.timeoutIntervalForResource = 20
		return configuration
	}

	/// Returns a random wait of up to 2^(retry - 1) seconds, as in the legacy retry mode that botocore and the AWS SDK for Swift use by default. The randomness keeps requests that were throttled together from retrying together.
	static func retryDelay(forRetry retry: Int) -> TimeInterval {
		return TimeInterval.random(in: 0 ... pow(2, TimeInterval(retry - 1)))
	}

	/// Returns the delay of the response's `Retry-After`, in seconds or as an HTTP date, or else `retryDelay(forRetry:)` of the attempt, capped at 60 seconds.
	static func retryDelay(for response: HTTPURLResponse, attempt: Int, now: Date) -> Duration {
		let retryAfter = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces)
		let delay: TimeInterval = if let retryAfter, let seconds = TimeInterval(retryAfter), seconds.isFinite, seconds >= 0 {
			seconds
		} else if let retryAfter, let date = Date.date(fromRFC822: retryAfter) {
			max(0, date.timeIntervalSince(now))
		} else {
			retryDelay(forRetry: attempt)
		}
		// `Duration.seconds(_:)` traps on an infinite or huge value.
		return .seconds(min(delay, maxRetryDelay))
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

	/// Returns the URL of a response if it is an HTTPS URL on the domain or one of its subdomains, because the requests to it carry the access token.
	static func httpsURL(_ string: String?, onDomain domain: String) -> URL? {
		guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https", let host = url.host(percentEncoded: true)?.lowercased(), host == domain || host.hasSuffix(".\(domain)") else {
			return nil
		}
		return url
	}

	/// The caller deletes the returned file.
	static func writeTemporaryFile(_ write: (FileHandle) throws -> Void) throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
		guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
			throw CocoaError(.fileWriteUnknown)
		}
		do {
			let fileHandle = try FileHandle(forWritingTo: url)
			defer {
				try? fileHandle.close()
			}
			try write(fileHandle)
		} catch {
			try? FileManager.default.removeItem(at: url)
			throw error
		}
		return url
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
