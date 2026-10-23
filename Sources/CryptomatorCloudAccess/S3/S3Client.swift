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

 Metadata requests are signed in the `Authorization` header and retried after transient failures and once after a clock skew. Downloads, uploads and the parts of multipart uploads run on presigned URLs, so that they can run on a background session. Downloads and uploads of whole objects aren't retried, whereas a part is retried after a transient failure with a newly presigned URL.

 Thrown errors never contain a request URL, and log lines contain request URLs only with their query values redacted. Neither contains a signature or a response body, because S3 error bodies echo the string to sign and the canonical request.
 */
final class S3Client: Sendable {
	/// The size of the largest part of a multipart upload or copy, and of the largest object copied in one request. AWS allows 5 GiB and Cloudflare R2 5 MiB less, while Backblaze B2 allows less than 5 GB, so this is rclone's limit of 4768 MiB.
	static let maxPartSize = 4768 * 1024 * 1024
	/// The most parts of a multipart upload. AWS, Cloudflare R2 and Backblaze B2 allow 10,000, but Scaleway only 1,000.
	static let maxPartCount = 1000
	private static let logLabel = "S3Client"
	private static let maxRetryCount = 3
	/// How long a presigned URL is valid, in seconds. It is also the resource timeout of a background transfer, as with AWS SDK 2.41.0.
	private static let presignedURLLifetime = 50 * 60
	private static let clockSkewTolerance: TimeInterval = 5 * 60
	private static let clockSkewErrorCodes: Set<String> = ["RequestTimeTooSkewed", "RequestExpired", "SignatureDoesNotMatch"]
	private static let transientStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
	private static let transientErrorCodes: Set<String> = ["InternalError", "ServiceUnavailable", "SlowDown", "RequestTimeout"]

	let endpoint: S3Endpoint
	private let signer: S3Signer
	private let session: SplitURLSession
	private let sleep: @Sendable (Duration) async throws -> Void
	/// The offset of the server's clock from the device's clock, which every signature adds to the current date.
	private let clockOffset = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

	/// - Throws: `URLError(.badURL)` if the credential's URL isn't an absolute HTTP or HTTPS URL with a host.
	init(credential: S3Credential, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks(), registry: BackgroundURLSessionRegistry = .shared, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
		self.endpoint = try S3Endpoint(credential: credential)
		self.signer = S3Signer(credential: credential)
		self.session = SplitURLSession(configuration: configuration, metadataConfiguration: metadataConfiguration, hooks: hooks, registry: registry)
		self.sleep = sleep
	}

	static func foreground(credential: S3Credential) throws -> S3Client {
		return try S3Client(credential: credential, configuration: HTTPClientSupport.hardened(.default), metadataConfiguration: nil)
	}

	/// Creates a client whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.
	static func background(credential: S3Credential, sessionIdentifier: String, sharedContainerIdentifier: String?) throws -> S3Client {
		return try S3Client(credential: credential, configuration: backgroundConfiguration(sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier), metadataConfiguration: HTTPClientSupport.hardened(.default))
	}

	static func backgroundConfiguration(sessionIdentifier: String, sharedContainerIdentifier: String?) -> URLSessionConfiguration {
		let configuration = HTTPClientSupport.hardenedBackground(identifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
		configuration.timeoutIntervalForResource = TimeInterval(presignedURLLifetime)
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

	/// - Parameter contentType: The content type of the object, or `nil` for the default of the server.
	func createMultipartUpload(key: String, contentType: String?) async throws -> String {
		return try await send(request(method: "POST", key: key, query: [URLQueryItem(name: "uploads", value: nil)], headers: contentType.map { ["Content-Type": $0] } ?? [:])) { body in
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

	/**
	 Creates a multipart upload, has `uploadParts` upload its parts, and completes it with the parts that `uploadParts` returns, in that order.

	 The completion commits the upload, so it runs to its end, with its retries, even if the task is cancelled meanwhile. Once the upload is created, any failure or cancellation before the completion, and a failed completion, abort it after `uploadParts` returned or threw. The abort runs without cancellation, so that its retries after a transient failure still run when the upload was cancelled.

	 - Parameter uploadParts: Gets the upload ID and returns the uploaded parts. It must return or throw only after every part it started finished, because S3 may keep a part that completes after the abort.
	 */
	func multipartUpload(key: String, contentType: String?, uploadParts: (String) async throws -> [S3CompletedPart]) async throws {
		let uploadID = try await createMultipartUpload(key: key, contentType: contentType)
		do {
			let parts = try await uploadParts(uploadID)
			try Task.checkCancellation()
			try await withoutCancellation {
				try await self.completeMultipartUpload(key: key, uploadID: uploadID, parts: parts)
			}
		} catch {
			try? await withoutCancellation {
				try await self.abortMultipartUpload(key: key, uploadID: uploadID)
			}
			throw error
		}
	}

	// MARK: - Transfers

	/// Downloads the object to `stagingURL`, at which no item may exist.
	func download(key: String, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws {
		let url = signer.presignedURL(method: "GET", url: endpoint.url(forKey: key), headers: [:], expiresIn: S3Client.presignedURLLifetime, date: currentDate())
		let request = URLRequest(url: url)
		let outcome = try await session.download(request, route: .transfer, handler: HTTPClientSupport.downloadHandler(movingTo: stagingURL, maxErrorBodyLength: HTTPClientSupport.maxErrorBodyLength), bodyLogging: .omitted, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: onTaskCreation)
		do {
			_ = try S3Client.successfulBody(of: outcome)
			guard case .file = outcome.body else {
				throw URLError(.badServerResponse)
			}
		} catch {
			HTTPClientSupport.logFailure(of: request, urlLogging: .redacted, with: error, label: S3Client.logLabel)
			throw error
		}
	}

	func upload(key: String, fromFile fileURL: URL, contentType: String, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws {
		let url = signer.presignedURL(method: "PUT", url: endpoint.url(forKey: key), headers: ["Content-Type": contentType], expiresIn: S3Client.presignedURLLifetime, date: currentDate())
		var request = URLRequest(url: url)
		request.httpMethod = "PUT"
		request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		let outcome = try await session.upload(request, fromFile: fileURL, bodyLimit: HTTPClientSupport.maxErrorBodyLength, bodyLogging: .omitted, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: onTaskCreation)
		do {
			_ = try S3Client.successfulBody(of: outcome)
		} catch {
			HTTPClientSupport.logFailure(of: request, urlLogging: .redacted, with: error, label: S3Client.logLabel)
			throw error
		}
	}

	/**
	 Uploads the file as the part with the given number of a multipart upload. A part that S3 already has with that number is replaced, so the upload is retried after a transient failure, as in `send`, with a newly presigned URL. Each retry adds a unit to the progress for its task.

	 - Returns: The ETag of the part.
	 */
	func uploadPart(key: String, uploadID: String, partNumber: Int, fromFile fileURL: URL, progress: Progress?) async throws -> String {
		let query = [URLQueryItem(name: "partNumber", value: String(partNumber)), URLQueryItem(name: "uploadId", value: uploadID)]
		var retryCount = 0
		while true {
			let url = signer.presignedURL(method: "PUT", url: endpoint.url(forKey: key, query: query), headers: [:], expiresIn: S3Client.presignedURLLifetime, date: currentDate())
			var request = URLRequest(url: url)
			request.httpMethod = "PUT"
			let outcome = try await session.upload(request, fromFile: fileURL, bodyLimit: HTTPClientSupport.maxErrorBodyLength, bodyLogging: .omitted, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: nil)
			let failure: Error
			do {
				_ = try S3Client.successfulBody(of: outcome)
				guard let eTag = (outcome.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") else {
					throw URLError(.badServerResponse)
				}
				return eTag
			} catch {
				failure = error
			}
			HTTPClientSupport.logFailure(of: request, urlLogging: .redacted, with: failure, label: S3Client.logLabel)
			try await waitBeforeRetry(after: failure, of: outcome, retryCount: &retryCount)
			progress?.totalUnitCount += 1
		}
	}

	// MARK: - Requests

	/**
	 Sends a metadata request, signing each attempt afresh, and returns the result that `result` reads from the body of a successful response.

	 A failed attempt is retried up to three times if its failure is transient. A transient failure is a connection that couldn't be made, dropped or timed out, including DNS and TLS failures. It is also a throttling, server or timeout status or error code; for a 2xx response, the code of its `<Error>` document counts. A 2xx response whose `<Error>` document or result can't be read is transient too (`S3ResponseError.unparseableResult`). A retry waits for the response's `Retry-After`, capped at 60 seconds, or else for a random exponential delay. A request that failed because of the device's clock is retried once with the server's clock.

	 A cancelled task stops the request instead of retrying it, also during the wait before a retry. The first attempt is sent and a running attempt finishes either way.
	 */
	func send<Output>(_ request: URLRequest, result: (Data) throws -> Output) async throws -> Output {
		let payloadHash = request.httpBody.map(S3Signer.sha256Hex) ?? S3Signer.emptyPayloadHash
		var retryCount = 0
		var hasCorrectedClockSkew = false
		while true {
			var signedRequest = request
			let signingOffset = clockOffset.withLock { $0 }
			signer.sign(&signedRequest, payloadHash: payloadHash, date: Date().addingTimeInterval(signingOffset))
			let outcome = try await session.data(signedRequest, bodyLimit: HTTPClientSupport.maxMetadataBodyLength, bodyLogging: .omitted)
			let failure: Error
			do {
				return try result(S3Client.successfulBody(of: outcome))
			} catch {
				failure = error
			}
			HTTPClientSupport.logFailure(of: request, urlLogging: .redacted, with: failure, label: S3Client.logLabel)
			if !hasCorrectedClockSkew, correctClockSkew(after: failure, response: outcome.response, signingOffset: signingOffset) {
				hasCorrectedClockSkew = true
				try Task.checkCancellation()
				continue
			}
			try await waitBeforeRetry(after: failure, of: outcome, retryCount: &retryCount)
		}
	}

	/// Throws the failure unless it is transient and retries are left, and otherwise counts the retry and waits for it. A cancelled task throws `CancellationError` instead of waiting.
	private func waitBeforeRetry(after failure: Error, of outcome: SplitURLSession.Outcome, retryCount: inout Int) async throws {
		guard retryCount < S3Client.maxRetryCount, S3Client.isTransient(failure) else {
			throw failure
		}
		retryCount += 1
		try Task.checkCancellation()
		try await sleep(HTTPClientSupport.retryDelay(of: outcome, retry: retryCount))
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
		guard let s3Error = failure as? S3Error, let code = s3Error.code, S3Client.clockSkewErrorCodes.contains(code), let serverDate = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date").flatMap({ Date.date(fromRFC822: $0) }) else {
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
		let httpResponse = try HTTPClientSupport.httpResponse(of: outcome)
		let body = outcome.data ?? Data()
		let bucketRegionHeader = httpResponse.value(forHTTPHeaderField: "x-amz-bucket-region")
		guard (200 ... 299).contains(httpResponse.statusCode) else {
			throw S3Error(statusCode: httpResponse.statusCode, body: body, bucketRegionHeader: bucketRegionHeader)
		}
		if let error = S3Error(errorDocument: body, statusCode: httpResponse.statusCode, bucketRegionHeader: bucketRegionHeader) {
			throw error
		}
		if S3XMLElement.rootName(of: body) == "Error" {
			throw S3ResponseError.unparseableResult
		}
		return body
	}

	private static func isTransient(_ error: Error) -> Bool {
		switch error {
		case let urlError as URLError:
			return HTTPClientSupport.isTransient(urlError)
		case let s3Error as S3Error:
			return transientStatusCodes.contains(s3Error.statusCode) || s3Error.code.map(transientErrorCodes.contains) ?? false
		case S3ResponseError.unparseableResult:
			return true
		default:
			return false
		}
	}
}
