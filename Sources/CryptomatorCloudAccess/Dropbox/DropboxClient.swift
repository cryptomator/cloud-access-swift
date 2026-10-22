//
//  DropboxClient.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Sends Dropbox API v2 requests for one account on a `SplitURLSession`.

 Every request carries the access token of its token source. A 401 refreshes the token and retries once. A 429, a 5xx and a 409 for too many write operations are retried. A request makes at most 5 attempts, counting the one after a refresh. A retry waits for the `retry_after` of a 429 or for `Retry-After`, capped at 60 seconds, or else for a random exponential delay. Transient transport errors are retried only for requests that are safe to repeat, because a repeated write could be applied twice.

 A cancelled task stops a request before each attempt, also during the wait before a retry. A running attempt finishes either way.

 The `Dropbox-API-Arg` and `Dropbox-API-Result` headers are logged, because they hold paths and metadata but no credentials. Thrown errors never contain a request URL.
 */
final class DropboxClient: Sendable {
	enum WriteMode: String, Encodable, Sendable {
		case add
		case overwrite
	}

	private static let maxAttemptCount = 5
	/// The maximum length of a response body that an upload reads, and of an error body that a download reads.
	private static let maxErrorBodyLength = 1024 * 1024

	private let tokenSource: any OAuthTokenSource
	private let session: SplitURLSession
	private let sleep: @Sendable (Duration) async throws -> Void

	init(tokenSource: any OAuthTokenSource, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks(), registry: BackgroundURLSessionRegistry = .shared, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
		self.tokenSource = tokenSource
		self.session = SplitURLSession(configuration: configuration, metadataConfiguration: metadataConfiguration, hooks: hooks, registry: registry)
		self.sleep = sleep
	}

	static func foreground(tokenSource: any OAuthTokenSource) -> DropboxClient {
		return DropboxClient(tokenSource: tokenSource, configuration: HTTPClientSupport.hardened(.default), metadataConfiguration: nil)
	}

	/// Creates a client whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.
	static func background(tokenSource: any OAuthTokenSource, sessionIdentifier: String) -> DropboxClient {
		return DropboxClient(tokenSource: tokenSource, configuration: HTTPClientSupport.hardenedBackground(identifier: sessionIdentifier, sharedContainerIdentifier: DropboxSetup.constants?.sharedContainerIdentifier), metadataConfiguration: HTTPClientSupport.hardened(.default))
	}

	// MARK: - Operations

	func metadata(path: String) async throws -> DropboxMetadata {
		let request = try DropboxClient.rpcRequest("files/get_metadata", body: DropboxArgument.json(GetMetadataArgument(path: path)))
		return try await DropboxJSON.decode(DropboxMetadata.self, from: data(request, repeatable: true))
	}

	/// - Parameter path: The folder's path, or `""` for the root.
	func listFolder(path: String, limit: Int) async throws -> DropboxListFolderResult {
		let request = try DropboxClient.rpcRequest("files/list_folder", body: DropboxArgument.json(ListFolderArgument(path: path, limit: limit)))
		return try await DropboxJSON.decode(DropboxListFolderResult.self, from: data(request, repeatable: true))
	}

	func listFolderContinue(cursor: String) async throws -> DropboxListFolderResult {
		let request = try DropboxClient.rpcRequest("files/list_folder/continue", body: DropboxArgument.json(CursorArgument(cursor: cursor)))
		return try await DropboxJSON.decode(DropboxListFolderResult.self, from: data(request, repeatable: true))
	}

	/// Its response isn't decoded, so that a body that fails to parse can't fail a folder that was created.
	func createFolder(path: String) async throws {
		_ = try await data(DropboxClient.rpcRequest("files/create_folder_v2", body: DropboxArgument.json(CreateFolderArgument(path: path))), repeatable: false)
	}

	/// Its response isn't decoded, so that a body that fails to parse can't fail an item that was deleted.
	func delete(path: String) async throws {
		_ = try await data(DropboxClient.rpcRequest("files/delete_v2", body: DropboxArgument.json(PathArgument(path: path))), repeatable: false)
	}

	/// Its response isn't decoded, so that a body that fails to parse can't fail an item that was moved.
	func move(from fromPath: String, to toPath: String) async throws {
		_ = try await data(DropboxClient.rpcRequest("files/move_v2", body: DropboxArgument.json(MoveArgument(fromPath: fromPath, toPath: toPath))), repeatable: false)
	}

	/// Its response, which carries the account's email, is never logged.
	func currentAccount() async throws -> DropboxAccount {
		let request = try DropboxClient.rpcRequest("users/get_current_account", body: Data("null".utf8))
		return try await DropboxJSON.decode(DropboxAccount.self, from: data(request, repeatable: true, bodyLogging: .omitted))
	}

	// MARK: - Transfers

	/**
	 Downloads the file to `stagingURL`, at which no item may exist.

	 - Returns: The file's metadata from the `Dropbox-API-Result` header.
	 */
	func download(path: String, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> DropboxMetadata {
		let request = try DropboxClient.contentRequest("files/download", argument: PathArgument(path: path), hasBody: false)
		let handler = HTTPClientSupport.downloadHandler(movingTo: stagingURL, maxErrorBodyLength: DropboxClient.maxErrorBodyLength)
		let (response, outcome) = try await send(request, repeatable: true, progress: progress) { request, isFirstAttempt in
			try await self.session.download(request, route: .transfer, handler: handler, bodyLogging: .logged, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
		_ = try DropboxClient.successfulBody(of: response, outcome, for: request)
		guard case .file = outcome.body, let result = response.value(forHTTPHeaderField: "Dropbox-API-Result") else {
			throw DropboxError.unexpectedContent
		}
		return try DropboxJSON.decode(DropboxMetadata.self, from: Data(result.utf8))
	}

	/// Uploads the file in a single request, which Dropbox accepts for files below 150 MiB.
	func upload(from fileURL: URL, path: String, mode: WriteMode, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> DropboxMetadata {
		let request = try DropboxClient.contentRequest("files/upload", argument: CommitArgument(path: path, mode: mode), hasBody: true)
		let (response, outcome) = try await send(request, repeatable: false, progress: progress) { request, isFirstAttempt in
			try await self.session.upload(request, fromFile: fileURL, bodyLimit: DropboxClient.maxErrorBodyLength, bodyLogging: .logged, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
		return try DropboxJSON.decode(DropboxMetadata.self, from: DropboxClient.successfulBody(of: response, outcome, for: request))
	}

	/// Starts an upload session without data. It is sent again after a transport error, because an unused session expires.
	func startUploadSession() async throws -> String {
		var request = try DropboxClient.contentRequest("files/upload_session/start", argument: StartArgument(close: false), hasBody: true)
		request.httpBody = Data()
		return try await DropboxJSON.decode(DropboxUploadSessionStart.self, from: data(request, repeatable: true)).sessionID
	}

	/**
	 Appends a chunk to the upload session from a file that holds just that chunk.

	 It is sent again after a transport error. If the lost attempt arrived, Dropbox answers the repeat with the offset to continue from.

	 - Returns: `nil` if Dropbox appended the chunk, or the offset that Dropbox expects if it rejected the offset.
	 */
	func appendToUploadSession(sessionID: String, offset: Int64, from chunkFileURL: URL, progress: Progress?) async throws -> Int64? {
		let request = try DropboxClient.contentRequest("files/upload_session/append_v2", argument: AppendArgument(cursor: CursorPosition(sessionId: sessionID, offset: offset), close: false), hasBody: true)
		let (response, outcome) = try await send(request, repeatable: true, progress: progress) { request, _ in
			try await self.session.upload(request, fromFile: chunkFileURL, bodyLimit: DropboxClient.maxErrorBodyLength, bodyLogging: .logged, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: nil)
		}
		if response.statusCode == 409, let errorResponse = DropboxErrorResponse.decode(from: outcome.data), DropboxErrorResponse.tags(of: errorResponse.errorSummary).first == "incorrect_offset", let correctOffset = errorResponse.error?.correctOffset {
			return correctOffset
		}
		_ = try DropboxClient.successfulBody(of: response, outcome, for: request)
		return nil
	}

	/// Commits the upload session without data. It isn't sent again after a transport error, because the lost attempt may have committed the file.
	func finishUploadSession(sessionID: String, offset: Int64, path: String, mode: WriteMode) async throws -> DropboxMetadata {
		var request = try DropboxClient.contentRequest("files/upload_session/finish", argument: FinishArgument(cursor: CursorPosition(sessionId: sessionID, offset: offset), commit: CommitArgument(path: path, mode: mode)), hasBody: true)
		request.httpBody = Data()
		return try await DropboxJSON.decode(DropboxMetadata.self, from: data(request, repeatable: false))
	}

	// MARK: - Requests

	/// Sends a request on the metadata session and returns the body of its successful response.
	private func data(_ request: URLRequest, repeatable: Bool, bodyLogging: HTTPDebugLogger.BodyLogging = .logged) async throws -> Data {
		let (response, outcome) = try await send(request, repeatable: repeatable) { request, _ in
			try await self.session.data(request, bodyLimit: nil, bodyLogging: bodyLogging)
		}
		return try DropboxClient.successfulBody(of: response, outcome, for: request)
	}

	/**
	 Makes the attempts of a request until one is final, and returns its response, whatever its status.

	 - Parameter repeatable: Whether the request is sent again after a transient transport error.
	 - Parameter progress: Gets the progress of every attempt with a pending unit count of 1. Its total unit count grows by 1 before each further attempt, so that the attempts never push it past complete.
	 - Parameter attempt: Sends the authorized request once. Gets whether it is the first attempt.
	 */
	private func send(_ request: URLRequest, repeatable: Bool, progress: Progress? = nil, attempt: (URLRequest, _ isFirstAttempt: Bool) async throws -> SplitURLSession.Outcome) async throws -> (HTTPURLResponse, SplitURLSession.Outcome) {
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
				DropboxClient.logFailure(of: request, with: error)
				// The retry decision reads the raw error, because most transient connection errors are also network connection errors.
				guard repeatable, attemptCount < DropboxClient.maxAttemptCount, (error as? URLError).map(HTTPClientSupport.isTransient) ?? false else {
					throw isNetworkConnectionError(error) ? CloudProviderError.noInternetConnection : error
				}
				try await sleep(.seconds(HTTPClientSupport.retryDelay(forRetry: attemptCount)))
				continue
			}
			guard attemptCount < DropboxClient.maxAttemptCount else {
				return (response, outcome)
			}
			if response.statusCode == 401, !hasRefreshed {
				hasRefreshed = true
				accessToken = try await tokenSource.refresh(rejecting: accessToken)
				continue
			}
			guard DropboxError.isRetryable(statusCode: response.statusCode, summary: DropboxErrorResponse.decode(from: outcome.data)?.errorSummary) else {
				return (response, outcome)
			}
			DropboxClient.logFailure(of: request, with: DropboxClient.apiError(of: response, outcome))
			try await sleep(DropboxClient.retryDelay(for: response, outcome, attempt: attemptCount))
		}
	}

	/// Returns the `retry_after` of a 429's body, or else the delay of `Retry-After` or of the attempt, capped at 60 seconds.
	private static func retryDelay(for response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome, attempt: Int) -> Duration {
		if response.statusCode == 429, let retryAfter = DropboxErrorResponse.decode(from: outcome.data)?.error?.retryAfter {
			// `Duration.seconds(_:)` traps on a huge value.
			return .seconds(min(max(retryAfter, 0), HTTPClientSupport.maxRetryDelay))
		}
		return HTTPClientSupport.retryDelay(for: response, attempt: attempt, now: Date())
	}

	/// An RPC request, whose argument is the JSON body. A route without an argument takes `null`.
	static func rpcRequest(_ route: String, body: Data) throws -> URLRequest {
		var request = try request(host: "api.dropboxapi.com", route: route)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = body
		return request
	}

	/// A content request, whose argument is the `Dropbox-API-Arg` header. Without a `Content-Type`, URLSession would send a body as form data, which Dropbox rejects.
	private static func contentRequest(_ route: String, argument: some Encodable, hasBody: Bool) throws -> URLRequest {
		var request = try request(host: "content.dropboxapi.com", route: route)
		try request.setValue(DropboxArgument.header(argument), forHTTPHeaderField: "Dropbox-API-Arg")
		if hasBody {
			request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
		}
		return request
	}

	private static func request(host: String, route: String) throws -> URLRequest {
		guard let url = URL(string: "https://\(host)/2/\(route)") else {
			throw URLError(.badURL)
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		return request
	}

	// MARK: - Outcomes

	private static func successfulBody(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome, for request: URLRequest) throws -> Data {
		guard (200 ... 299).contains(response.statusCode) else {
			let error = apiError(of: response, outcome)
			logFailure(of: request, with: error)
			throw error
		}
		return outcome.data ?? Data()
	}

	static func apiError(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome) -> DropboxError {
		return .apiError(statusCode: response.statusCode, summary: DropboxErrorResponse.summary(of: outcome.data, statusCode: response.statusCode))
	}

	private static func logFailure(of request: URLRequest, with error: Error) {
		CloudAccessDDLogDebug("DropboxClient: \(request.httpMethod ?? "POST") \(request.url?.path ?? "") failed with \(error)")
	}
}

// MARK: - Arguments

private struct PathArgument: Encodable {
	let path: String
}

private struct GetMetadataArgument: Encodable {
	let path: String
	let includeMediaInfo = false
	let includeDeleted = false
	let includeHasExplicitSharedMembers = false
}

private struct ListFolderArgument: Encodable {
	let path: String
	let limit: Int
	let recursive = false
	let includeMountedFolders = true
	let includeNonDownloadableFiles = true
}

private struct CursorArgument: Encodable {
	let cursor: String
}

private struct CreateFolderArgument: Encodable {
	let path: String
	let autorename = false
}

private struct MoveArgument: Encodable {
	let fromPath: String
	let toPath: String
	let allowSharedFolder = false
	let autorename = false
	let allowOwnershipTransfer = false
}

private struct CommitArgument: Encodable {
	let path: String
	let mode: DropboxClient.WriteMode
	let autorename = false
	let mute = false
	let strictConflict = true
}

private struct StartArgument: Encodable {
	let close: Bool
}

private struct CursorPosition: Encodable {
	let sessionId: String
	let offset: Int64
}

private struct AppendArgument: Encodable {
	let cursor: CursorPosition
	let close: Bool
}

private struct FinishArgument: Encodable {
	let cursor: CursorPosition
	let commit: CommitArgument
}
