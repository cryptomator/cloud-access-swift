//
//  GoogleDriveClient.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Sends Google Drive API requests for one account on a `SplitURLSession`.

 Every request carries the access token of its token source. A 401 refreshes the token and retries once. A 408, 429, 500, 502, 503, 504 and a 403 for exceeded rate limits are retried until 5 attempts were made, the retry after a refresh included. A retry waits for `Retry-After`, capped at 60 seconds, or else for a random exponential delay. Transport errors are retried only for a `GET` and for the requests of an upload that create nothing, because a repeated `POST` could create an item twice.

 A cancelled task stops a request before each attempt, also during the wait before a retry. A running attempt finishes either way.

 Downloads log their URLs only as origins, and an upload logs its session URL, which is a credential, only as origin or with its query redacted. Thrown errors never contain a request URL.
 */
final class GoogleDriveClient: Sendable {
	fileprivate static let maxAttemptCount = 5
	/// The maximum length of a response body that an upload reads, and of an error body that a download reads.
	private static let maxErrorBodyLength = 1024 * 1024
	private static let uploadFields = "id,name,modifiedTime,size,mimeType"

	private let tokenSource: any OAuthTokenSource
	private let session: SplitURLSession
	private let sleep: @Sendable (Duration) async throws -> Void

	init(tokenSource: any OAuthTokenSource, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks(), registry: BackgroundURLSessionRegistry = .shared, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
		self.tokenSource = tokenSource
		self.session = SplitURLSession(configuration: configuration, metadataConfiguration: metadataConfiguration, hooks: hooks, registry: registry)
		self.sleep = sleep
	}

	static func foreground(tokenSource: any OAuthTokenSource) -> GoogleDriveClient {
		return GoogleDriveClient(tokenSource: tokenSource, configuration: HTTPClientSupport.hardened(.default), metadataConfiguration: nil)
	}

	/// Creates a client whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.
	static func background(tokenSource: any OAuthTokenSource, sessionIdentifier: String) -> GoogleDriveClient {
		return GoogleDriveClient(tokenSource: tokenSource, configuration: HTTPClientSupport.hardenedBackground(identifier: sessionIdentifier, sharedContainerIdentifier: GoogleDriveSetup.constants?.sharedContainerIdentifier), metadataConfiguration: HTTPClientSupport.hardened(.default))
	}

	// MARK: - Operations

	func file(id: String, fields: String) async throws -> GoogleDriveFile {
		let url = try GoogleDriveClient.apiURL("/files/\(GoogleDriveClient.pathComponent(id))", parameters: [("supportsAllDrives", "true"), ("fields", fields)])
		return try await GoogleDriveJSON.decode(GoogleDriveFile.self, from: data(GoogleDriveClient.request("GET", url)))
	}

	/// - Parameter query: A search query, see `query(inFolder:named:)`.
	func files(query: String, pageSize: Int?, pageToken: String?, fields: String) async throws -> GoogleDriveFileList {
		var parameters = [("q", query), ("supportsAllDrives", "true"), ("includeItemsFromAllDrives", "true")]
		if let pageSize {
			parameters.append(("pageSize", String(pageSize)))
		}
		if let pageToken {
			parameters.append(("pageToken", pageToken))
		}
		parameters.append(("fields", fields))
		return try await GoogleDriveJSON.decode(GoogleDriveFileList.self, from: data(GoogleDriveClient.request("GET", GoogleDriveClient.apiURL("/files", parameters: parameters))))
	}

	func createFolder(name: String, parentID: String) async throws -> GoogleDriveFile {
		let request = try GoogleDriveClient.request("POST", GoogleDriveClient.apiURL("/files", parameters: [("supportsAllDrives", "true")]), json: GoogleDriveFileMetadata(name: name, parents: [parentID], mimeType: GoogleDriveJSON.folderMimeType))
		return try await GoogleDriveJSON.decode(GoogleDriveFile.self, from: data(request))
	}

	func delete(id: String) async throws {
		_ = try await data(GoogleDriveClient.request("DELETE", GoogleDriveClient.apiURL("/files/\(GoogleDriveClient.pathComponent(id))", parameters: [("supportsAllDrives", "true")])))
	}

	/// Renames the item, and moves it if `addParents` and `removeParents` are given.
	func update(id: String, name: String, addParents: String?, removeParents: String?, fields: String) async throws -> GoogleDriveFile {
		var parameters = [("supportsAllDrives", "true")]
		if let addParents, let removeParents {
			parameters += [("addParents", addParents), ("removeParents", removeParents)]
		}
		parameters.append(("fields", fields))
		let request = try GoogleDriveClient.request("PATCH", GoogleDriveClient.apiURL("/files/\(GoogleDriveClient.pathComponent(id))", parameters: parameters), json: GoogleDriveFileMetadata(name: name, parents: nil, mimeType: nil))
		return try await GoogleDriveJSON.decode(GoogleDriveFile.self, from: data(request))
	}

	/// Its response, which carries the account's email, is never logged.
	func about() async throws -> GoogleDriveAbout {
		let request = try GoogleDriveClient.request("GET", GoogleDriveClient.apiURL("/about", parameters: [("fields", "user(emailAddress)")]))
		return try await GoogleDriveJSON.decode(GoogleDriveAbout.self, from: data(request, bodyLogging: .omitted))
	}

	/// The query of the items in a folder that aren't trashed and, if a name is given, whose names contain it. Google matches `name contains` by prefix of words, so the caller compares the names.
	static func query(inFolder folderID: String, named name: String? = nil) -> String {
		var query = "'\(escapedQueryValue(folderID))' in parents"
		if let name {
			query += " and name contains '\(escapedQueryValue(name))'"
		}
		return query + " and trashed = false"
	}

	private static func escapedQueryValue(_ value: String) -> String {
		return value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
	}

	// MARK: - Transfers

	/// Downloads the content of the file to `stagingURL`, at which no item may exist.
	func download(fileID: String, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws {
		let request = try GoogleDriveClient.request("GET", GoogleDriveClient.url(path: "/download/drive/v3/files/\(GoogleDriveClient.pathComponent(fileID))", parameters: [("alt", "media"), ("supportsAllDrives", "true")]))
		let handler = HTTPClientSupport.downloadHandler(movingTo: stagingURL, maxErrorBodyLength: GoogleDriveClient.maxErrorBodyLength)
		let (response, outcome) = try await send(request, progress: progress) { request, isFirstAttempt in
			try await self.session.download(request, route: .transfer, handler: handler, bodyLogging: .logged, urlLogging: .originOnly, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
		_ = try GoogleDriveClient.successfulBody(of: response, outcome, for: request)
		guard case .file = outcome.body else {
			throw GoogleDriveError.unexpectedContent
		}
	}

	/**
	 Uploads the file as a new file into the folder, or as new content of an existing file, with one resumable upload session that receives the whole file in each `PUT` rather than in chunks.

	 The requests of the upload share one budget of 5 attempts and one refresh. Its session request and status query create nothing, so they are also sent again after a transport error. Once a `PUT` was sent, its failure doesn't prove that Drive didn't create the file, so the upload asks the session for its status instead of starting a new session. It sends the file again only if no byte arrived, and otherwise fails, leaving the partial session to expire.

	 - Parameter name: The name of a new file. An existing file keeps its name, which differs from the path's name if the file is a shortcut's target.
	 - Parameter onTaskCreation: Gets the task of the first `PUT`.
	 */
	// swiftlint:disable:next function_parameter_count
	func upload(from fileURL: URL, name: String, parentID: String, existingFileID: String?, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> GoogleDriveFile {
		let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
		var upload = try ResumableUpload(sessionRequest: GoogleDriveClient.uploadSessionRequest(name: name, parentID: parentID, existingFileID: existingFileID, fileSize: fileSize))
		try Task.checkCancellation()
		upload.accessToken = try await tokenSource.accessToken()
		while true {
			try Task.checkCancellation()
			switch upload.step {
			case .createSession:
				try await createSession(&upload)
			case let .put(sessionURL):
				if let file = try await put(fileURL, to: sessionURL, progress: progress, onTaskCreation: onTaskCreation, &upload) {
					return file
				}
			case let .queryStatus(sessionURL):
				if let file = try await queryStatus(of: sessionURL, fileSize: fileSize, &upload) {
					return file
				}
			}
		}
	}

	private func createSession(_ upload: inout ResumableUpload) async throws {
		// The session is of no use without an attempt left for its `PUT`.
		try upload.startAttempt(reserving: 1)
		let request = upload.sessionRequest
		let outcome = try await session.data(upload.authorized(request), bodyLimit: GoogleDriveClient.maxErrorBodyLength, bodyLogging: .logged)
		if let response = try await handleOutcome(outcome, of: request, reserving: 1, in: &upload) {
			upload.step = try .put(GoogleDriveClient.uploadSessionURL(response.value(forHTTPHeaderField: "Location")))
		}
	}

	/// - Returns: The uploaded file, or `nil` if the upload continues.
	private func put(_ fileURL: URL, to sessionURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?, _ upload: inout ResumableUpload) async throws -> GoogleDriveFile? {
		try upload.startAttempt()
		// Each further `PUT` adds a unit, so that its task's progress doesn't push the total past complete.
		let taskHook = upload.hasSentFile ? nil : onTaskCreation
		if upload.hasSentFile {
			progress?.totalUnitCount += 1
		}
		upload.hasSentFile = true
		var request = GoogleDriveClient.request("PUT", sessionURL)
		request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
		let outcome = try await session.upload(upload.authorized(request), fromFile: fileURL, bodyLimit: GoogleDriveClient.maxErrorBodyLength, bodyLogging: .logged, urlLogging: .originOnly, progress: progress, cancelsBeforeResume: true, onTaskCreation: taskHook)
		guard let response = try await handleOutcome(outcome, of: request, reserving: 0, in: &upload) else {
			upload.step = .queryStatus(sessionURL)
			return nil
		}
		switch response.statusCode {
		case 200, 201:
			return try GoogleDriveJSON.decode(GoogleDriveFile.self, from: outcome.data ?? Data())
		default:
			throw GoogleDriveClient.apiError(of: response, outcome, for: request)
		}
	}

	/// - Returns: The uploaded file, or `nil` if the upload continues.
	private func queryStatus(of sessionURL: URL, fileSize: Int64, _ upload: inout ResumableUpload) async throws -> GoogleDriveFile? {
		try upload.startAttempt()
		var request = GoogleDriveClient.request("PUT", sessionURL)
		request.setValue("bytes */\(fileSize)", forHTTPHeaderField: "Content-Range")
		request.httpBody = Data()
		let outcome = try await session.data(upload.authorized(request), bodyLimit: GoogleDriveClient.maxErrorBodyLength, bodyLogging: .logged)
		guard let response = try await handleOutcome(outcome, of: request, reserving: 0, in: &upload) else {
			return nil
		}
		switch response.statusCode {
		case 200, 201:
			return try GoogleDriveJSON.decode(GoogleDriveFile.self, from: outcome.data ?? Data())
		case 308 where response.value(forHTTPHeaderField: "Range") == nil:
			// No byte arrived, so the file is sent again to the same session.
			upload.step = .put(sessionURL)
			return nil
		case 308:
			// Part of the file arrived, which this upload can't continue, because it sends the whole file in one `PUT`.
			GoogleDriveClient.logFailure(of: request, with: "a partial upload")
			throw GoogleDriveClient.converted(upload.lastFailure ?? GoogleDriveError.unexpectedContent)
		default:
			throw GoogleDriveClient.apiError(of: response, outcome, for: request)
		}
	}

	/**
	 Handles the outcome of an upload's request. After a retryable failure, the upload continues after a wait, and after the first 401, it continues after a refresh: the session request and the status query are sent again, and a failed `PUT` is followed by the status query.

	 - Parameter reservedAttemptCount: The attempts that must remain after the next one.
	 - Returns: The response to evaluate, or `nil` if the upload continues.
	 */
	private func handleOutcome(_ outcome: SplitURLSession.Outcome, of request: URLRequest, reserving reservedAttemptCount: Int, in upload: inout ResumableUpload) async throws -> HTTPURLResponse? {
		let response: HTTPURLResponse
		do {
			response = try HTTPClientSupport.httpResponse(of: outcome)
		} catch {
			GoogleDriveClient.logFailure(of: request, with: error)
			guard GoogleDriveClient.isTransient(error) else {
				throw GoogleDriveClient.converted(error)
			}
			upload.lastFailure = error
			try upload.checkAttemptLeft(reserving: reservedAttemptCount)
			try await sleep(.seconds(HTTPClientSupport.retryDelay(forRetry: upload.attemptCount)))
			return nil
		}
		if response.statusCode == 401, !upload.hasRefreshed {
			upload.lastFailure = GoogleDriveClient.apiError(of: response, outcome, for: request)
			try upload.checkAttemptLeft(reserving: reservedAttemptCount)
			try await refresh(&upload)
			return nil
		}
		if GoogleDriveClient.isRetryable(response, outcome) {
			upload.lastFailure = GoogleDriveClient.apiError(of: response, outcome, for: request)
			try upload.checkAttemptLeft(reserving: reservedAttemptCount)
			try await sleep(HTTPClientSupport.retryDelay(for: response, attempt: upload.attemptCount, now: Date()))
			return nil
		}
		if (200 ... 299).contains(response.statusCode) || response.statusCode == 308 {
			return response
		}
		throw GoogleDriveClient.apiError(of: response, outcome, for: request)
	}

	private func refresh(_ upload: inout ResumableUpload) async throws {
		upload.hasRefreshed = true
		upload.accessToken = try await tokenSource.refresh(rejecting: upload.accessToken)
	}

	// MARK: - Requests

	/// Sends a request on the metadata session and returns the body of its successful response.
	private func data(_ request: URLRequest, bodyLogging: HTTPDebugLogger.BodyLogging = .logged) async throws -> Data {
		let (response, outcome) = try await send(request) { request, _ in
			try await self.session.data(request, bodyLimit: nil, bodyLogging: bodyLogging)
		}
		return try GoogleDriveClient.successfulBody(of: response, outcome, for: request)
	}

	/**
	 Makes the attempts of a request until one is final, and returns its response, whatever its status.

	 - Parameter progress: Gets the progress of every attempt with a pending unit count of 1. Its total unit count grows by 1 before each further attempt, so that the attempts never push it past complete.
	 - Parameter attempt: Sends the authorized request once. Gets whether it is the first attempt.
	 */
	private func send(_ request: URLRequest, progress: Progress? = nil, attempt: (URLRequest, _ isFirstAttempt: Bool) async throws -> SplitURLSession.Outcome) async throws -> (HTTPURLResponse, SplitURLSession.Outcome) {
		try Task.checkCancellation()
		var accessToken = try await tokenSource.accessToken()
		var attemptCount = 0
		var hasRefreshed = false
		while true {
			try Task.checkCancellation()
			if attemptCount > 0 {
				progress?.totalUnitCount += 1
			}
			attemptCount += 1
			var authorizedRequest = request
			authorizedRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
			let outcome = try await attempt(authorizedRequest, attemptCount == 1)
			let response: HTTPURLResponse
			do {
				response = try HTTPClientSupport.httpResponse(of: outcome)
			} catch {
				GoogleDriveClient.logFailure(of: request, with: error)
				// The retry decision reads the raw error, because most transient connection errors are also network connection errors.
				guard request.httpMethod == "GET", attemptCount < GoogleDriveClient.maxAttemptCount, GoogleDriveClient.isTransient(error) else {
					throw GoogleDriveClient.converted(error)
				}
				try await sleep(.seconds(HTTPClientSupport.retryDelay(forRetry: attemptCount)))
				continue
			}
			guard attemptCount < GoogleDriveClient.maxAttemptCount else {
				return (response, outcome)
			}
			if response.statusCode == 401, !hasRefreshed {
				hasRefreshed = true
				accessToken = try await tokenSource.refresh(rejecting: accessToken)
				continue
			}
			guard GoogleDriveClient.isRetryable(response, outcome) else {
				return (response, outcome)
			}
			GoogleDriveClient.logFailure(of: request, with: GoogleDriveClient.apiError(of: response, outcome))
			try await sleep(HTTPClientSupport.retryDelay(for: response, attempt: attemptCount, now: Date()))
		}
	}

	private static func isRetryable(_ response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome) -> Bool {
		let reason = response.statusCode == 403 ? errorResponse(of: outcome)?.error?.errors?.first?.reason : nil
		return GoogleDriveError.isRetryable(statusCode: response.statusCode, reason: reason)
	}

	private static func isTransient(_ error: Error) -> Bool {
		return (error as? URLError).map(HTTPClientSupport.isTransient) ?? false
	}

	fileprivate static func converted(_ error: Error) -> Error {
		return isNetworkConnectionError(error) ? CloudProviderError.noInternetConnection : error
	}

	private static func request(_ method: String, _ url: URL) -> URLRequest {
		var request = URLRequest(url: url)
		request.httpMethod = method
		return request
	}

	private static func request(_ method: String, _ url: URL, json body: some Encodable) throws -> URLRequest {
		var request = GoogleDriveClient.request(method, url)
		request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONEncoder().encode(body)
		return request
	}

	private static func uploadSessionRequest(name: String, parentID: String, existingFileID: String?, fileSize: Int64) throws -> URLRequest {
		let parameters = [("uploadType", "resumable"), ("supportsAllDrives", "true"), ("fields", uploadFields)]
		var request = if let existingFileID {
			try GoogleDriveClient.request("PATCH", url(path: "/upload/drive/v3/files/\(pathComponent(existingFileID))", parameters: parameters), json: GoogleDriveFileMetadata(name: nil, parents: nil, mimeType: nil))
		} else {
			try GoogleDriveClient.request("POST", url(path: "/upload/drive/v3/files", parameters: parameters), json: GoogleDriveFileMetadata(name: name, parents: [parentID], mimeType: nil))
		}
		request.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
		request.setValue(String(fileSize), forHTTPHeaderField: "X-Upload-Content-Length")
		return request
	}

	private static func apiURL(_ path: String, parameters: [(String, String)]) throws -> URL {
		return try url(path: "/drive/v3\(path)", parameters: parameters)
	}

	private static func url(path percentEncodedPath: String, parameters: [(String, String)]) throws -> URL {
		var components = URLComponents()
		components.scheme = "https"
		components.host = "www.googleapis.com"
		components.percentEncodedPath = percentEncodedPath
		// Unlike `queryItems`, this also escapes `+`, which the server would read as a space.
		components.percentEncodedQuery = HTTPClientSupport.formEncoded(parameters)
		guard let url = components.url else {
			throw URLError(.badURL)
		}
		return url
	}

	/// Escapes an identifier from a response as one path component.
	private static func pathComponent(_ identifier: String) -> String {
		return HTTPClientSupport.percentEncoded(identifier, encodeSlash: true)
	}

	private static func uploadSessionURL(_ string: String?) throws -> URL {
		guard let url = HTTPClientSupport.httpsURL(string, onDomain: "googleapis.com") else {
			throw GoogleDriveError.unexpectedContent
		}
		return url
	}

	// MARK: - Outcomes

	private static func successfulBody(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome, for request: URLRequest) throws -> Data {
		guard (200 ... 299).contains(response.statusCode) else {
			throw apiError(of: response, outcome, for: request)
		}
		return outcome.data ?? Data()
	}

	/// Returns the error of an unsuccessful response, and logs it if a request is given.
	private static func apiError(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome, for request: URLRequest? = nil) -> GoogleDriveError {
		let body = errorResponse(of: outcome)?.error
		let error = GoogleDriveError.apiError(statusCode: response.statusCode, reason: body?.errors?.first?.reason, message: body?.message)
		if let request {
			logFailure(of: request, with: error)
		}
		return error
	}

	private static func errorResponse(of outcome: SplitURLSession.Outcome) -> GoogleDriveErrorResponse? {
		return outcome.data.flatMap { try? JSONDecoder().decode(GoogleDriveErrorResponse.self, from: $0) }
	}

	private static func logFailure(of request: URLRequest, with failure: Any) {
		CloudAccessDDLogDebug("GoogleDriveClient: \(request.httpMethod ?? "GET") \(request.url?.path ?? "") failed with \(failure)")
	}
}

/// The state of one resumable upload, whose requests share one budget of attempts and one refresh.
private struct ResumableUpload {
	enum Step {
		case createSession
		case put(URL)
		case queryStatus(URL)
	}

	let sessionRequest: URLRequest
	var step = Step.createSession
	var accessToken = ""
	var attemptCount = 0
	var hasSentFile = false
	var hasRefreshed = false
	/// The latest failure of the upload's requests, which the upload throws once no attempt is left or part of the file arrived.
	var lastFailure: Error?

	/**
	 Counts an attempt.

	 - Parameter reservedAttemptCount: The attempts that must remain after this one.
	 - Throws: The last failure if not enough attempts are left.
	 */
	mutating func startAttempt(reserving reservedAttemptCount: Int = 0) throws {
		try checkAttemptLeft(reserving: reservedAttemptCount)
		attemptCount += 1
	}

	/**
	 Checks that another attempt is left, before the upload waits or refreshes for it.

	 - Parameter reservedAttemptCount: The attempts that must remain after the next one.
	 - Throws: The last failure if not enough attempts are left.
	 */
	func checkAttemptLeft(reserving reservedAttemptCount: Int = 0) throws {
		guard attemptCount + 1 + reservedAttemptCount <= GoogleDriveClient.maxAttemptCount else {
			throw lastFailure.map(GoogleDriveClient.converted) ?? GoogleDriveError.unexpectedContent
		}
	}

	func authorized(_ request: URLRequest) -> URLRequest {
		var request = request
		request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
		return request
	}
}
