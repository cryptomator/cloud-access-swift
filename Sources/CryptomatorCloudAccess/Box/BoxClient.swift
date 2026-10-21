//
//  BoxClient.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Sends Box API requests for one account on a `SplitURLSession`.

 Every request carries the access token of its token source. A 401 refreshes the token and retries once. A 429, a server error and a 202 with `Retry-After` are retried until 5 attempts were made. Such a 202 means that a download or an upload isn't processed yet. A retry waits for `Retry-After`, capped at 60 seconds, or else for a random exponential delay. Transport errors aren't retried. Every request is retried this way, mutations included.

 A cancelled task stops a request before each attempt, also during the wait before a retry. A running attempt finishes either way.

 Downloads log their URLs only as origins, because Box redirects them to a pre-authenticated URL. Thrown errors never contain a request URL.
 */
final class BoxClient: Sendable {
	private static let maxAttemptCount = 5
	/// The maximum length of a response body that an upload reads, and of an error body that a download reads.
	private static let maxErrorBodyLength = 1024 * 1024
	/// The length of the chunks in which a file is copied into a temporary file.
	static let bufferLength = 64 * 1024
	private static let listingFields = "name,size,modified_at"

	private let tokenSource: any OAuthTokenSource
	private let session: SplitURLSession
	private let sleep: @Sendable (Duration) async throws -> Void

	init(tokenSource: any OAuthTokenSource, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks(), registry: BackgroundURLSessionRegistry = .shared, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
		self.tokenSource = tokenSource
		self.session = SplitURLSession(configuration: configuration, metadataConfiguration: metadataConfiguration, hooks: hooks, registry: registry)
		self.sleep = sleep
	}

	static func foreground(tokenSource: any OAuthTokenSource) -> BoxClient {
		return BoxClient(tokenSource: tokenSource, configuration: HTTPClientSupport.hardened(.default), metadataConfiguration: nil)
	}

	/// Creates a client whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.
	static func background(tokenSource: any OAuthTokenSource, sessionIdentifier: String) -> BoxClient {
		return BoxClient(tokenSource: tokenSource, configuration: HTTPClientSupport.hardenedBackground(identifier: sessionIdentifier, sharedContainerIdentifier: BoxSetup.constants?.sharedContainerIdentifier), metadataConfiguration: HTTPClientSupport.hardened(.default))
	}

	// MARK: - Operations

	func file(id: String) async throws -> BoxEntry {
		return try await BoxJSON.decode(BoxEntry.self, from: data(BoxClient.request("GET", BoxClient.apiURL("/files/\(BoxClient.pathComponent(id))"))))
	}

	func folder(id: String) async throws -> BoxEntry {
		return try await BoxJSON.decode(BoxEntry.self, from: data(BoxClient.request("GET", BoxClient.apiURL("/folders/\(BoxClient.pathComponent(id))"))))
	}

	func folderItems(id: String, marker: String?, limit: Int) async throws -> BoxItems {
		var parameters = [("fields", BoxClient.listingFields), ("usemarker", "true")]
		if let marker {
			parameters.append(("marker", marker))
		}
		parameters.append(("limit", String(limit)))
		return try await BoxJSON.decode(BoxItems.self, from: data(BoxClient.request("GET", BoxClient.apiURL("/folders/\(BoxClient.pathComponent(id))/items", parameters: parameters))))
	}

	/// Its response, which carries the account's login email, is never logged.
	func user() async throws -> BoxUser {
		return try await BoxJSON.decode(BoxUser.self, from: data(BoxClient.request("GET", BoxClient.apiURL("/users/me")), bodyLogging: .omitted))
	}

	func createFolder(name: String, parentID: String) async throws -> BoxEntry {
		let request = try BoxClient.request("POST", BoxClient.apiURL("/folders"), json: BoxItemRequest(name: name, parent: BoxParentReference(id: parentID)))
		return try await BoxJSON.decode(BoxEntry.self, from: data(request))
	}

	func deleteFile(id: String) async throws {
		_ = try await data(BoxClient.request("DELETE", BoxClient.apiURL("/files/\(BoxClient.pathComponent(id))")))
	}

	func deleteFolder(id: String) async throws {
		_ = try await data(BoxClient.request("DELETE", BoxClient.apiURL("/folders/\(BoxClient.pathComponent(id))", parameters: [("recursive", "true")])))
	}

	func moveFile(id: String, name: String, parentID: String) async throws -> BoxEntry {
		let request = try BoxClient.request("PUT", BoxClient.apiURL("/files/\(BoxClient.pathComponent(id))"), json: BoxItemRequest(name: name, parent: BoxParentReference(id: parentID)))
		return try await BoxJSON.decode(BoxEntry.self, from: data(request))
	}

	func moveFolder(id: String, name: String, parentID: String) async throws -> BoxEntry {
		let request = try BoxClient.request("PUT", BoxClient.apiURL("/folders/\(BoxClient.pathComponent(id))"), json: BoxItemRequest(name: name, parent: BoxParentReference(id: parentID)))
		return try await BoxJSON.decode(BoxEntry.self, from: data(request))
	}

	// MARK: - Transfers

	/**
	 Downloads the file to `stagingURL`, at which no item may exist.

	 - Throws: `BoxError.fileNotReady` if Box still answered that the file isn't ready after the last attempt, in which case nothing is left at `stagingURL`.
	 */
	func download(fileID: String, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws {
		let request = try BoxClient.request("GET", BoxClient.apiURL("/files/\(BoxClient.pathComponent(fileID))/content"))
		let handler = BoxClient.downloadHandler(movingTo: stagingURL)
		let (response, outcome) = try await send(request, progress: progress) { request, isFirstAttempt in
			try await self.session.download(request, route: .transfer, handler: handler, bodyLogging: .logged, urlLogging: .originOnly, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
		_ = try BoxClient.successfulBody(of: response, outcome, for: request)
		guard case .file = outcome.body else {
			throw BoxError.unexpectedContent
		}
	}

	/// Uploads the file as `name` into the folder in a single request.
	func uploadNewFile(from fileURL: URL, name: String, parentID: String, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> BoxFiles {
		return try await uploadMultipart(BoxClient.uploadURL("/files/content"), attributes: BoxItemRequest(name: name, parent: BoxParentReference(id: parentID)), from: fileURL, progress: progress, onTaskCreation: onTaskCreation)
	}

	/// Uploads the file as a new version of an existing file in a single request.
	func uploadFileVersion(from fileURL: URL, fileID: String, name: String, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> BoxFiles {
		return try await uploadMultipart(BoxClient.uploadURL("/files/\(BoxClient.pathComponent(fileID))/content"), attributes: BoxItemRequest(name: name, parent: nil), from: fileURL, progress: progress, onTaskCreation: onTaskCreation)
	}

	func createUploadSession(parentID: String, name: String, fileSize: Int64) async throws -> BoxUploadSession {
		let request = try BoxClient.request("POST", BoxClient.uploadURL("/files/upload_sessions"), json: BoxUploadSessionRequest(folderID: parentID, fileSize: fileSize, fileName: name))
		return try await BoxJSON.decode(BoxUploadSession.self, from: data(request))
	}

	func createUploadSession(fileID: String, fileSize: Int64) async throws -> BoxUploadSession {
		let request = try BoxClient.request("POST", BoxClient.uploadURL("/files/\(BoxClient.pathComponent(fileID))/upload_sessions"), json: BoxUploadSessionRequest(folderID: nil, fileSize: fileSize, fileName: nil))
		return try await BoxJSON.decode(BoxUploadSession.self, from: data(request))
	}

	/**
	 Uploads one part of a chunked upload from a file that holds just that part.

	 - Parameter url: The `upload_part` endpoint of the upload session.
	 - Parameter range: The offsets of the part's first and last byte in the file.
	 - Parameter digest: The `digest` header, `sha=` followed by the base64 SHA-1 of the part.
	 */
	// swiftlint:disable:next function_parameter_count
	func uploadPart(url: String, from partFileURL: URL, range: ClosedRange<Int64>, fileSize: Int64, digest: String, progress: Progress?) async throws -> BoxPart {
		var request = try BoxClient.request("PUT", BoxClient.uploadSessionURL(url))
		request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
		request.setValue(digest, forHTTPHeaderField: "digest")
		request.setValue("bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)", forHTTPHeaderField: "content-range")
		let (response, outcome) = try await send(request, progress: progress) { request, _ in
			try await self.session.upload(request, fromFile: partFileURL, bodyLimit: BoxClient.maxErrorBodyLength, bodyLogging: .logged, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: nil)
		}
		guard let part = try BoxJSON.decode(BoxUploadedPart.self, from: BoxClient.successfulBody(of: response, outcome, for: request)).part else {
			throw BoxError.unexpectedContent
		}
		return part
	}

	/**
	 Commits a chunked upload.

	 - Parameter url: The `commit` endpoint of the upload session.
	 - Parameter digest: The `digest` header, `sha=` followed by the base64 SHA-1 of the file.
	 - Throws: `BoxError.fileNotReady` if Box was still processing the upload after the last attempt.
	 */
	func commit(url: String, parts: [BoxPart], digest: String) async throws -> BoxFiles {
		var request = try BoxClient.request("POST", BoxClient.uploadSessionURL(url), json: BoxCommitRequest(parts: parts))
		request.setValue(digest, forHTTPHeaderField: "digest")
		return try await BoxJSON.decode(BoxFiles.self, from: data(request))
	}

	// MARK: - Requests

	/// Sends a request on the metadata session and returns the body of its successful response.
	private func data(_ request: URLRequest, bodyLogging: HTTPDebugLogger.BodyLogging = .logged) async throws -> Data {
		let (response, outcome) = try await send(request) { request, _ in
			try await self.session.data(request, bodyLimit: nil, bodyLogging: bodyLogging)
		}
		return try BoxClient.successfulBody(of: response, outcome, for: request)
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
				BoxClient.logFailure(of: request, with: error)
				throw isNetworkConnectionError(error) ? CloudProviderError.noInternetConnection : error
			}
			if response.statusCode == 401, !hasRefreshed {
				hasRefreshed = true
				accessToken = try await tokenSource.refresh(rejecting: accessToken)
				continue
			}
			guard BoxClient.isRetryable(response), attemptCount < BoxClient.maxAttemptCount else {
				return (response, outcome)
			}
			BoxClient.logFailure(of: request, with: BoxClient.apiError(of: response, outcome))
			try await sleep(HTTPClientSupport.retryDelay(for: response, attempt: attemptCount, now: Date()))
		}
	}

	private static func isRetryable(_ response: HTTPURLResponse) -> Bool {
		switch response.statusCode {
		case 202:
			return response.value(forHTTPHeaderField: "Retry-After") != nil
		case 429, 500...:
			return true
		default:
			return false
		}
	}

	private static func request(_ method: String, _ url: URL) -> URLRequest {
		var request = URLRequest(url: url)
		request.httpMethod = method
		return request
	}

	private static func request(_ method: String, _ url: URL, json body: some Encodable) throws -> URLRequest {
		var request = BoxClient.request(method, url)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONEncoder().encode(body)
		return request
	}

	private static func apiURL(_ path: String, parameters: [(String, String)] = []) throws -> URL {
		return try url(host: "api.box.com", percentEncodedPath: "/2.0\(path)", parameters: parameters)
	}

	private static func uploadURL(_ path: String) throws -> URL {
		return try url(host: "upload.box.com", percentEncodedPath: "/api/2.0\(path)", parameters: [])
	}

	private static func url(host: String, percentEncodedPath: String, parameters: [(String, String)]) throws -> URL {
		var components = URLComponents()
		components.scheme = "https"
		components.host = host
		components.percentEncodedPath = percentEncodedPath
		if !parameters.isEmpty {
			// Unlike `queryItems`, this also escapes `+`, which the server would read as a space.
			components.percentEncodedQuery = HTTPClientSupport.formEncoded(parameters)
		}
		guard let url = components.url else {
			throw URLError(.badURL)
		}
		return url
	}

	/// Escapes an identifier from a response as one path component.
	private static func pathComponent(_ identifier: String) -> String {
		return HTTPClientSupport.percentEncoded(identifier, encodeSlash: true)
	}

	private static func uploadSessionURL(_ string: String) throws -> URL {
		guard let url = HTTPClientSupport.httpsURL(string, onDomain: "box.com") else {
			throw BoxError.unexpectedContent
		}
		return url
	}

	// MARK: - Bodies

	private func uploadMultipart(_ url: URL, attributes: BoxItemRequest, from fileURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> BoxFiles {
		let boundary = "Boundary-\(UUID().uuidString)"
		let attributesData = try JSONEncoder().encode(attributes)
		// The body is written once, so that every attempt uploads it from the same file.
		let bodyFileURL = try BoxClient.writeTemporaryFile { fileHandle in
			try fileHandle.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n".utf8))
			try fileHandle.write(contentsOf: attributesData)
			try fileHandle.write(contentsOf: Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
			let sourceHandle = try FileHandle(forReadingFrom: fileURL)
			defer {
				try? sourceHandle.close()
			}
			while let chunk = try sourceHandle.read(upToCount: BoxClient.bufferLength), !chunk.isEmpty {
				try fileHandle.write(contentsOf: chunk)
			}
			try fileHandle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
		}
		defer {
			try? FileManager.default.removeItem(at: bodyFileURL)
		}
		var request = BoxClient.request("POST", url)
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		let (response, outcome) = try await send(request, progress: progress) { request, isFirstAttempt in
			try await self.session.upload(request, fromFile: bodyFileURL, bodyLimit: BoxClient.maxErrorBodyLength, bodyLogging: .logged, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
		return try BoxJSON.decode(BoxFiles.self, from: BoxClient.successfulBody(of: response, outcome, for: request))
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

	// MARK: - Outcomes

	/// Moves the body of a 2xx response to `stagingURL`, except that of a 202, which means that the file isn't ready yet. Its body must not take the place of the following 200's.
	private static func downloadHandler(movingTo stagingURL: URL) -> SplitURLSession.DownloadHandler {
		let handler = HTTPClientSupport.downloadHandler(movingTo: stagingURL, maxErrorBodyLength: maxErrorBodyLength)
		return { location, response in
			if (response as? HTTPURLResponse)?.statusCode == 202 {
				return .none
			}
			return try handler(location, response)
		}
	}

	/**
	 Returns the body of a successful response.

	 - Throws: `BoxError.fileNotReady` for a 202, which only a download or a commit that isn't processed yet returns, and `BoxError.apiError` for an unsuccessful status.
	 */
	private static func successfulBody(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome, for request: URLRequest) throws -> Data {
		let error: BoxError
		switch response.statusCode {
		case 202:
			error = .fileNotReady
		case 200 ... 299:
			return outcome.data ?? Data()
		default:
			error = apiError(of: response, outcome)
		}
		logFailure(of: request, with: error)
		throw error
	}

	private static func apiError(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome) -> BoxError {
		let errorResponse = outcome.data.flatMap { try? JSONDecoder().decode(BoxErrorResponse.self, from: $0) }
		return .apiError(statusCode: response.statusCode, code: errorResponse?.code, message: errorResponse?.message)
	}

	private static func logFailure(of request: URLRequest, with error: Error) {
		CloudAccessDDLogDebug("BoxClient: \(request.httpMethod ?? "GET") \(request.url?.path ?? "") failed with \(error)")
	}
}
