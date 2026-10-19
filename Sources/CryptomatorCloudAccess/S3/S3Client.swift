//
//  S3Client.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import Foundation
import os

/**
 Sends signed S3 requests for one bucket on a `SplitURLSession`.

 Metadata requests are signed in the `Authorization` header and retried after transient failures and once after a clock skew. Downloads and uploads run on presigned URLs, so that they can run on a background session, and aren't retried.

 Thrown errors never contain a request URL, and log lines contain request URLs only with their query values redacted. Neither contains a signature or a response body, because S3 error bodies echo the string to sign and the canonical request.
 */
final class S3Client: Sendable {
	private static let maxRetryCount = 3
	/// How long a presigned URL is valid, in seconds. It is also the resource timeout of a background transfer, as with AWS SDK 2.41.0.
	private static let presignedURLLifetime = 50 * 60
	/// The maximum length of an error body that is read from a download or an upload.
	private static let maxErrorBodyLength = 1024 * 1024
	private static let clockSkewTolerance: TimeInterval = 5 * 60
	private static let clockSkewErrorCodes: Set<String> = ["RequestTimeTooSkewed", "RequestExpired", "SignatureDoesNotMatch"]
	private static let transientURLErrorCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost]
	private static let transientStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
	private static let transientErrorCodes: Set<String> = ["InternalError", "ServiceUnavailable", "SlowDown", "RequestTimeout"]
	private static let failingURLKeys = [NSURLErrorFailingURLErrorKey, NSURLErrorFailingURLStringErrorKey, NSURLErrorFailingURLPeerTrustErrorKey]

	let endpoint: S3Endpoint
	private let signer: S3Signer
	private let session: SplitURLSession
	/// The offset of the server's clock from the device's clock, which every signature adds to the current date.
	private let clockOffset = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

	init(credential: S3Credential, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, registry: BackgroundURLSessionRegistry = .shared) {
		self.endpoint = S3Endpoint(credential: credential)
		self.signer = S3Signer(credential: credential)
		self.session = SplitURLSession(configuration: configuration, metadataConfiguration: metadataConfiguration, registry: registry)
	}

	static func foreground(credential: S3Credential) -> S3Client {
		return S3Client(credential: credential, configuration: hardened(.default), metadataConfiguration: nil)
	}

	/// Creates a client whose downloads and uploads run on a background URL session, which all clients of the account share, and whose other requests run on a foreground URL session.
	static func background(credential: S3Credential, sharedContainerIdentifier: String?) -> S3Client {
		return S3Client(credential: credential, configuration: backgroundConfiguration(credential: credential, sharedContainerIdentifier: sharedContainerIdentifier), metadataConfiguration: hardened(.default))
	}

	static func backgroundConfiguration(credential: S3Credential, sharedContainerIdentifier: String?) -> URLSessionConfiguration {
		let configuration = hardened(.background(withIdentifier: "CryptomatorCloudAccess.S3.\(credential.identifier)"))
		configuration.sharedContainerIdentifier = sharedContainerIdentifier
		configuration.timeoutIntervalForResource = TimeInterval(presignedURLLifetime)
		return configuration
	}

	static func hardened(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
		configuration.httpCookieStorage = HTTPCookieStorage()
		configuration.urlCredentialStorage = nil
		// A listing must never be answered from a cached response, e.g., when an upload checks for an existing item.
		configuration.urlCache = nil
		return configuration
	}

	// MARK: - Operations

	func listObjectsV2(prefix: String, delimiter: String?, continuationToken: String?, maxKeys: Int) async throws -> S3ListObjectsResult {
		var query = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "prefix", value: prefix), URLQueryItem(name: "max-keys", value: String(maxKeys))]
		if let delimiter {
			query.append(URLQueryItem(name: "delimiter", value: delimiter))
		}
		if let continuationToken {
			query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
		}
		return try await send(request(method: "GET", key: "", query: query)) { body in
			try S3ListObjectsResult(xml: body)
		}
	}

	func putEmptyObject(key: String, contentType: String) async throws {
		try await send(request(method: "PUT", key: key, headers: ["Content-Type": contentType])) { _ in }
	}

	func deleteObject(key: String) async throws {
		try await send(request(method: "DELETE", key: key)) { _ in }
	}

	/// Deletes the objects in quiet mode. The errors of single objects in a successful response are not reported.
	func deleteObjects(keys: [String]) async throws {
		let body = S3XML.deleteObjectsBody(keys: keys)
		let contentMD5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
		try await send(request(method: "POST", key: "", query: [URLQueryItem(name: "delete", value: nil)], headers: ["Content-MD5": contentMD5, "Content-Type": "application/xml"], body: body)) { _ in }
	}

	func copyObject(sourceKey: String, targetKey: String) async throws {
		try await send(request(method: "PUT", key: targetKey, headers: ["x-amz-copy-source": endpoint.copySource(forKey: sourceKey)])) { body in
			_ = try S3XML.copyETag(in: body)
		}
	}

	func createMultipartUpload(key: String) async throws -> String {
		return try await send(request(method: "POST", key: key, query: [URLQueryItem(name: "uploads", value: nil)])) { body in
			try S3XML.uploadID(in: body)
		}
	}

	/// - Parameter range: The range of the source to copy, in the form `bytes=first-last`.
	/// - Returns: The ETag of the part.
	func uploadPartCopy(sourceKey: String, range: String, key: String, uploadID: String, partNumber: Int) async throws -> String {
		let query = [URLQueryItem(name: "partNumber", value: String(partNumber)), URLQueryItem(name: "uploadId", value: uploadID)]
		return try await send(request(method: "PUT", key: key, query: query, headers: ["x-amz-copy-source": endpoint.copySource(forKey: sourceKey), "x-amz-copy-source-range": range])) { body in
			try S3XML.copyETag(in: body)
		}
	}

	func completeMultipartUpload(key: String, uploadID: String, parts: [S3CompletedPart]) async throws {
		let body = S3XML.completeMultipartUploadBody(parts: parts)
		try await send(request(method: "POST", key: key, query: [URLQueryItem(name: "uploadId", value: uploadID)], headers: ["Content-Type": "application/xml"], body: body)) { body in
			try S3XML.validateCompleteMultipartUploadResult(body)
		}
	}

	func abortMultipartUpload(key: String, uploadID: String) async throws {
		try await send(request(method: "DELETE", key: key, query: [URLQueryItem(name: "uploadId", value: uploadID)])) { _ in }
	}

	// MARK: - Transfers

	/// Downloads the object to `stagingURL`, at which no item may exist.
	func download(key: String, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws {
		let url = signer.presignedURL(method: "GET", url: endpoint.url(forKey: key), headers: [:], expiresIn: S3Client.presignedURLLifetime, date: currentDate())
		let request = URLRequest(url: url)
		let outcome = try await session.download(request, route: .transfer, handler: S3Client.downloadHandler(movingTo: stagingURL), bodyLogging: .omitted, progress: progress, cancelsBeforeResume: true, onTaskCreation: onTaskCreation)
		do {
			_ = try S3Client.successfulBody(of: outcome)
			guard case .file = outcome.body else {
				throw URLError(.badServerResponse)
			}
		} catch {
			S3Client.logFailure(of: request, with: error)
			throw error
		}
	}

	func upload(key: String, fromFile fileURL: URL, contentType: String, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws {
		let url = signer.presignedURL(method: "PUT", url: endpoint.url(forKey: key), headers: ["Content-Type": contentType], expiresIn: S3Client.presignedURLLifetime, date: currentDate())
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"
		request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		let outcome = try await session.upload(request, fromFile: fileURL, bodyLimit: S3Client.maxErrorBodyLength, bodyLogging: .omitted, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: onTaskCreation)
		do {
			_ = try S3Client.successfulBody(of: outcome)
		} catch {
			S3Client.logFailure(of: request, with: error)
			throw error
		}
	}

	/// Moves the body of a 2xx response to `stagingURL`, and returns a short body of any other response as data, so that its error can be parsed.
	private static func downloadHandler(movingTo stagingURL: URL) -> SplitURLSession.DownloadHandler {
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

	// MARK: - Requests

	/**
	 Sends a metadata request, signing each attempt afresh, and returns the result that `result` reads from the body of a successful response.

	 A failed attempt is retried up to three times if its failure is transient: a dropped or timed-out connection, a throttling or server error status or code, also in an `<Error>` document of a 2xx response, or a 2xx response whose `<Error>` document or result can't be read (`S3ResponseError.unparseableResult`). A request that failed because of the device's clock is retried once with the server's clock. The wait before a retry is the only point at which a cancelled task stops the request.
	 */
	func send<Output>(_ request: URLRequest, result: (Data) throws -> Output) async throws -> Output {
		let payloadHash = request.httpBody.map(S3Signer.sha256Hex) ?? S3Signer.emptyPayloadHash
		var retryCount = 0
		var hasCorrectedClockSkew = false
		while true {
			var signedRequest = request
			let signingOffset = clockOffset.withLock { $0 }
			signer.sign(&signedRequest, payloadHash: payloadHash, date: Date().addingTimeInterval(signingOffset))
			let outcome = try await session.data(signedRequest, bodyLimit: nil, bodyLogging: .omitted)
			let failure: Error
			do {
				return try result(S3Client.successfulBody(of: outcome))
			} catch {
				failure = error
			}
			S3Client.logFailure(of: request, with: failure)
			if !hasCorrectedClockSkew, correctClockSkew(after: failure, response: outcome.response, signingOffset: signingOffset) {
				hasCorrectedClockSkew = true
				continue
			}
			guard retryCount < S3Client.maxRetryCount, S3Client.isTransient(failure) else {
				throw failure
			}
			retryCount += 1
			try await Task.sleep(for: .seconds(1 + 2 * retryCount))
		}
	}

	private func request(method: String, key: String, query: [URLQueryItem] = [], headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
		var request = URLRequest(url: endpoint.url(forKey: key, query: query))
		request.httpMethod = method
		for (name, value) in headers {
			request.setValue(value, forHTTPHeaderField: name)
		}
		// An empty body makes URLSession send `Content-Length: 0`, which S3 requires for a PUT or POST.
		request.httpBody = body ?? (["PUT", "POST"].contains(method) ? Data() : nil)
		return request
	}

	// MARK: - Clock Skew

	private func currentDate() -> Date {
		return Date().addingTimeInterval(clockOffset.withLock { $0 })
	}

	/// Adopts the clock of the server if the request failed because the offset it was signed with is off, and returns whether it did. The offset of the attempt counts rather than the current one, because concurrent requests may have been signed before another one corrected it.
	private func correctClockSkew(after failure: Error, response: URLResponse?, signingOffset: TimeInterval) -> Bool {
		guard let s3Error = failure as? S3Error, s3Error.statusCode == 403, let code = s3Error.code, S3Client.clockSkewErrorCodes.contains(code), let serverDate = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date").flatMap({ Date.date(fromRFC822: $0) }) else {
			return false
		}
		let offset = serverDate.timeIntervalSinceNow
		guard abs(offset - signingOffset) > S3Client.clockSkewTolerance else {
			return false
		}
		clockOffset.withLock { $0 = offset }
		return true
	}

	// MARK: - Outcomes

	/// Returns the body of a 2xx response that isn't an `<Error>` document, and throws its error otherwise.
	static func successfulBody(of outcome: SplitURLSession.Outcome) throws -> Data {
		if let recordedFailure = outcome.recordedFailure {
			throw sanitized(recordedFailure)
		}
		if let error = outcome.error {
			throw isCancellationError(error) ? CancellationError() : sanitized(error)
		}
		guard let httpResponse = outcome.response as? HTTPURLResponse else {
			throw URLError(.badServerResponse)
		}
		let body = outcome.data ?? Data()
		guard (200 ... 299).contains(httpResponse.statusCode) else {
			throw S3Error(statusCode: httpResponse.statusCode, body: body)
		}
		if let error = S3Error(errorDocument: body, statusCode: httpResponse.statusCode) {
			throw error
		}
		if S3XMLElement.rootName(of: body) == "Error" {
			throw S3ResponseError.unparseableResult
		}
		return body
	}

	/// Returns the error without the URL of its request, which is a credential for a presigned URL. A `URLError` keeps only its code. Any other error keeps its domain, code and the rest of its user info.
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

	private static func isTransient(_ error: Error) -> Bool {
		switch error {
		case let urlError as URLError:
			return transientURLErrorCodes.contains(urlError.code)
		case let s3Error as S3Error:
			return transientStatusCodes.contains(s3Error.statusCode) || s3Error.code.map(transientErrorCodes.contains) ?? false
		case S3ResponseError.unparseableResult:
			return true
		default:
			return false
		}
	}

	private static func logFailure(of request: URLRequest, with error: Error) {
		CloudAccessDDLogDebug("S3Client: \(request.httpMethod ?? "GET") \(HTTPDebugLogger.redactedURLString(request.url)) failed with \(error)")
	}
}
