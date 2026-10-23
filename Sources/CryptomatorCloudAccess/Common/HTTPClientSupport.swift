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
	/// The maximum length of the body of a metadata response, e.g., a listing. A page of 1000 Microsoft Graph items without `$select` is about 1.5 MB.
	static let maxMetadataBodyLength = 16 * 1024 * 1024
	/// The maximum length of a response body that an upload reads, and of an error body that a download reads.
	static let maxErrorBodyLength = 1024 * 1024

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

	/// Returns the delay of the attempt's response as `retryDelay(for:attempt:now:)` does, or else `retryDelay(forRetry:)`, e.g., after a transport error.
	static func retryDelay(of outcome: SplitURLSession.Outcome, retry: Int) -> Duration {
		guard let response = outcome.response as? HTTPURLResponse else {
			return .seconds(retryDelay(forRetry: retry))
		}
		return retryDelay(for: response, attempt: retry, now: Date())
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

	static func uploadSessionURL(_ string: String?, onDomain domain: String, orThrow error: @autoclosure () -> Error) throws -> URL {
		guard let url = httpsURL(string, onDomain: domain) else {
			throw error()
		}
		return url
	}

	// MARK: - Requests

	static func request(_ method: String, _ url: URL) -> URLRequest {
		var request = URLRequest(url: url)
		request.httpMethod = method
		return request
	}

	/// - Parameter charset: The `charset` parameter of the `Content-Type`, if the server expects one.
	static func request(_ method: String, _ url: URL, json body: some Encodable, charset: String? = nil) throws -> URLRequest {
		var request = request(method, url)
		request.setValue("application/json\(charset.map { "; charset=\($0)" } ?? "")", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONEncoder().encode(body)
		return request
	}

	static func url(host: String, percentEncodedPath: String, parameters: [(String, String)]) throws -> URL {
		var components = URLComponents()
		components.scheme = "https"
		components.host = host
		components.percentEncodedPath = percentEncodedPath
		if !parameters.isEmpty {
			// Unlike `queryItems`, this also escapes `+`, which the server would read as a space.
			components.percentEncodedQuery = formEncoded(parameters)
		}
		guard let url = components.url else {
			throw URLError(.badURL)
		}
		return url
	}

	/// Escapes an identifier from a response as one path component.
	static func pathComponent(_ identifier: String) -> String {
		return percentEncoded(identifier, encodeSlash: true)
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

	/**
	 Copies up to `maxLength` bytes from the current offset of the file handle into a temporary file, which the caller deletes.

	 - Returns: The temporary file and the number of bytes copied, which is 0 at the end of the file.
	 */
	static func writeTemporaryFile(copyingUpTo maxLength: Int, from fileHandle: FileHandle) throws -> (URL, Int) {
		var writtenLength = 0
		let url = try writeTemporaryFile { temporaryFileHandle in
			while writtenLength < maxLength, let data = try fileHandle.read(upToCount: min(temporaryFileBufferLength, maxLength - writtenLength)), !data.isEmpty {
				try temporaryFileHandle.write(contentsOf: data)
				writtenLength += data.count
			}
		}
		return (url, writtenLength)
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

	// MARK: - Outcomes

	/// Returns the body of a response for which `failure` returns `nil`. Otherwise it logs the request's failure and throws the error that `failure` returns.
	// swiftlint:disable:next function_parameter_count
	static func successfulBody(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome, for request: URLRequest, urlLogging: HTTPDebugLogger.URLLogging, label: String, failure: (HTTPURLResponse, SplitURLSession.Outcome) -> Error?) throws -> Data {
		if let error = failure(response, outcome) {
			logFailure(of: request, urlLogging: urlLogging, with: error, label: label)
			throw error
		}
		return outcome.data ?? Data()
	}

	static func logFailure(of request: URLRequest, urlLogging: HTTPDebugLogger.URLLogging, with failure: Any, label: String) {
		CloudAccessDDLogDebug("\(label): \(request.httpMethod ?? "GET") \(HTTPDebugLogger.redactedURLString(request.url, urlLogging: urlLogging)) failed with \(failure)")
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
