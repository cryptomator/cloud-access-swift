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

 Requests are sent by a `BearerRequestSender`. A 429, a server error and a 202 with `Retry-After` are retried, mutations included. Such a 202 means that a download or an upload isn't processed yet. Transient transport errors are retried only for a `GET`, because a repeated mutation could be applied twice.

 The bodies of metadata responses and of single-request uploads aren't logged, because they name the account, e.g., by its login email. Downloads log their URLs only as origins, because Box redirects them to a pre-authenticated URL. Thrown errors never contain a request URL.
 */
final class BoxClient: Sendable {
	private static let logLabel = "BoxClient"
	private static let listingFields = "name,size,modified_at"

	private let session: SplitURLSession
	private let sender: BearerRequestSender

	init(tokenSource: any OAuthTokenSource, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks(), registry: BackgroundURLSessionRegistry = .shared, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
		self.session = SplitURLSession(configuration: configuration, metadataConfiguration: metadataConfiguration, hooks: hooks, registry: registry)
		self.sender = BearerRequestSender(tokenSource: tokenSource, logLabel: BoxClient.logLabel, sleep: sleep)
	}

	static func foreground(tokenSource: any OAuthTokenSource) -> BoxClient {
		return BoxClient(tokenSource: tokenSource, configuration: HTTPClientSupport.hardened(.default), metadataConfiguration: nil)
	}

	/// Creates a client whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.
	static func background(tokenSource: any OAuthTokenSource, sessionIdentifier: String, sharedContainerIdentifier: String?) -> BoxClient {
		return BoxClient(tokenSource: tokenSource, configuration: backgroundConfiguration(sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier), metadataConfiguration: HTTPClientSupport.hardened(.default))
	}

	static func backgroundConfiguration(sessionIdentifier: String, sharedContainerIdentifier: String?) -> URLSessionConfiguration {
		return HTTPClientSupport.hardenedBackground(identifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
	}

	// MARK: - Operations

	func file(id: String) async throws -> BoxEntry {
		return try await BoxJSON.decode(BoxEntry.self, from: data(HTTPClientSupport.request("GET", BoxClient.apiURL("/files/\(HTTPClientSupport.pathComponent(id))"))))
	}

	func folder(id: String) async throws -> BoxEntry {
		return try await BoxJSON.decode(BoxEntry.self, from: data(HTTPClientSupport.request("GET", BoxClient.apiURL("/folders/\(HTTPClientSupport.pathComponent(id))"))))
	}

	func folderItems(id: String, marker: String?, limit: Int) async throws -> BoxItems {
		var parameters = [("fields", BoxClient.listingFields), ("usemarker", "true")]
		if let marker {
			parameters.append(("marker", marker))
		}
		parameters.append(("limit", String(limit)))
		return try await BoxJSON.decode(BoxItems.self, from: data(HTTPClientSupport.request("GET", BoxClient.apiURL("/folders/\(HTTPClientSupport.pathComponent(id))/items", parameters: parameters))))
	}

	func user() async throws -> BoxUser {
		return try await BoxJSON.decode(BoxUser.self, from: data(HTTPClientSupport.request("GET", BoxClient.apiURL("/users/me"))))
	}

	func createFolder(name: String, parentID: String) async throws -> BoxEntry {
		let request = try HTTPClientSupport.request("POST", BoxClient.apiURL("/folders"), json: BoxItemRequest(name: name, parent: BoxParentReference(id: parentID)))
		return try await BoxJSON.decode(BoxEntry.self, from: data(request))
	}

	func deleteFile(id: String) async throws {
		_ = try await data(HTTPClientSupport.request("DELETE", BoxClient.apiURL("/files/\(HTTPClientSupport.pathComponent(id))")))
	}

	func deleteFolder(id: String) async throws {
		_ = try await data(HTTPClientSupport.request("DELETE", BoxClient.apiURL("/folders/\(HTTPClientSupport.pathComponent(id))", parameters: [("recursive", "true")])))
	}

	func moveFile(id: String, name: String, parentID: String) async throws -> BoxEntry {
		let request = try HTTPClientSupport.request("PUT", BoxClient.apiURL("/files/\(HTTPClientSupport.pathComponent(id))"), json: BoxItemRequest(name: name, parent: BoxParentReference(id: parentID)))
		return try await BoxJSON.decode(BoxEntry.self, from: data(request))
	}

	func moveFolder(id: String, name: String, parentID: String) async throws -> BoxEntry {
		let request = try HTTPClientSupport.request("PUT", BoxClient.apiURL("/folders/\(HTTPClientSupport.pathComponent(id))"), json: BoxItemRequest(name: name, parent: BoxParentReference(id: parentID)))
		return try await BoxJSON.decode(BoxEntry.self, from: data(request))
	}

	// MARK: - Transfers

	/**
	 Downloads the file to `stagingURL`, at which no item may exist.

	 - Throws: `BoxError.fileNotReady` if Box still answered that the file isn't ready after the last attempt, in which case nothing is left at `stagingURL`.
	 */
	func download(fileID: String, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws {
		let request = try HTTPClientSupport.request("GET", BoxClient.apiURL("/files/\(HTTPClientSupport.pathComponent(fileID))/content"))
		let handler = BoxClient.downloadHandler(movingTo: stagingURL)
		let (response, outcome) = try await send(request, urlLogging: .originOnly, progress: progress) { request, isFirstAttempt in
			try await self.session.download(request, route: .transfer, handler: handler, bodyLogging: .logged, urlLogging: .originOnly, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
		_ = try BoxClient.successfulBody(of: response, outcome, for: request, urlLogging: .originOnly)
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
		return try await uploadMultipart(BoxClient.uploadURL("/files/\(HTTPClientSupport.pathComponent(fileID))/content"), attributes: BoxItemRequest(name: name, parent: nil), from: fileURL, progress: progress, onTaskCreation: onTaskCreation)
	}

	func createUploadSession(parentID: String, name: String, fileSize: Int64) async throws -> BoxUploadSession {
		let request = try HTTPClientSupport.request("POST", BoxClient.uploadURL("/files/upload_sessions"), json: BoxUploadSessionRequest(folderID: parentID, fileSize: fileSize, fileName: name))
		return try await BoxJSON.decode(BoxUploadSession.self, from: data(request))
	}

	func createUploadSession(fileID: String, fileSize: Int64) async throws -> BoxUploadSession {
		let request = try HTTPClientSupport.request("POST", BoxClient.uploadURL("/files/\(HTTPClientSupport.pathComponent(fileID))/upload_sessions"), json: BoxUploadSessionRequest(folderID: nil, fileSize: fileSize, fileName: nil))
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
		var request = try HTTPClientSupport.request("PUT", HTTPClientSupport.uploadSessionURL(url, onDomain: "box.com", orThrow: BoxError.unexpectedContent))
		request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
		request.setValue(digest, forHTTPHeaderField: "digest")
		request.setValue("bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)", forHTTPHeaderField: "content-range")
		let (response, outcome) = try await send(request, urlLogging: .redacted, progress: progress) { request, _ in
			try await self.session.upload(request, fromFile: partFileURL, bodyLimit: HTTPClientSupport.maxErrorBodyLength, bodyLogging: .logged, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: nil)
		}
		guard let part = try BoxJSON.decode(BoxUploadedPart.self, from: BoxClient.successfulBody(of: response, outcome, for: request, urlLogging: .redacted)).part else {
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
		var request = try HTTPClientSupport.request("POST", HTTPClientSupport.uploadSessionURL(url, onDomain: "box.com", orThrow: BoxError.unexpectedContent), json: BoxCommitRequest(parts: parts))
		request.setValue(digest, forHTTPHeaderField: "digest")
		return try await BoxJSON.decode(BoxFiles.self, from: data(request))
	}

	// MARK: - Requests

	/// Sends a request on the metadata session and returns the body of its successful response.
	private func data(_ request: URLRequest) async throws -> Data {
		let (response, outcome) = try await send(request, urlLogging: .redacted) { request, _ in
			try await self.session.data(request, bodyLimit: HTTPClientSupport.maxMetadataBodyLength, bodyLogging: .omitted)
		}
		return try BoxClient.successfulBody(of: response, outcome, for: request, urlLogging: .redacted)
	}

	private func send(_ request: URLRequest, urlLogging: HTTPDebugLogger.URLLogging, progress: Progress? = nil, attempt: (URLRequest, _ isFirstAttempt: Bool) async throws -> SplitURLSession.Outcome) async throws -> (HTTPURLResponse, SplitURLSession.Outcome) {
		let policy = RetryPolicy(retriesTransportErrors: request.httpMethod == "GET", isRetryable: { response, _ in BoxClient.isRetryable(response) }, failure: BoxClient.apiError(of:_:))
		return try await sender.send(request, urlLogging: urlLogging, policy: policy, progress: progress, attempt: attempt)
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

	private static func apiURL(_ path: String, parameters: [(String, String)] = []) throws -> URL {
		return try HTTPClientSupport.url(host: "api.box.com", percentEncodedPath: "/2.0\(path)", parameters: parameters)
	}

	private static func uploadURL(_ path: String) throws -> URL {
		return try HTTPClientSupport.url(host: "upload.box.com", percentEncodedPath: "/api/2.0\(path)", parameters: [])
	}

	// MARK: - Bodies

	private func uploadMultipart(_ url: URL, attributes: BoxItemRequest, from fileURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> BoxFiles {
		let boundary = "Boundary-\(UUID().uuidString)"
		let attributesData = try JSONEncoder().encode(attributes)
		// The body is written once, so that every attempt uploads it from the same file.
		let bodyFileURL = try HTTPClientSupport.writeTemporaryFile { fileHandle in
			try fileHandle.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n".utf8))
			try fileHandle.write(contentsOf: attributesData)
			try fileHandle.write(contentsOf: Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
			let sourceHandle = try FileHandle(forReadingFrom: fileURL)
			defer {
				try? sourceHandle.close()
			}
			while let chunk = try sourceHandle.read(upToCount: HTTPClientSupport.temporaryFileBufferLength), !chunk.isEmpty {
				try fileHandle.write(contentsOf: chunk)
			}
			try fileHandle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
		}
		defer {
			try? FileManager.default.removeItem(at: bodyFileURL)
		}
		var request = HTTPClientSupport.request("POST", url)
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		let (response, outcome) = try await send(request, urlLogging: .redacted, progress: progress) { request, isFirstAttempt in
			try await self.session.upload(request, fromFile: bodyFileURL, bodyLimit: HTTPClientSupport.maxErrorBodyLength, bodyLogging: .omitted, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
		return try BoxJSON.decode(BoxFiles.self, from: BoxClient.successfulBody(of: response, outcome, for: request, urlLogging: .redacted))
	}

	// MARK: - Outcomes

	/// Moves the body of a 2xx response to `stagingURL`, except that of a 202, which means that the file isn't ready yet. Its body must not take the place of the following 200's.
	private static func downloadHandler(movingTo stagingURL: URL) -> SplitURLSession.DownloadHandler {
		let handler = HTTPClientSupport.downloadHandler(movingTo: stagingURL, maxErrorBodyLength: HTTPClientSupport.maxErrorBodyLength)
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
	private static func successfulBody(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome, for request: URLRequest, urlLogging: HTTPDebugLogger.URLLogging) throws -> Data {
		return try HTTPClientSupport.successfulBody(of: response, outcome, for: request, urlLogging: urlLogging, label: logLabel) { response, outcome in
			switch response.statusCode {
			case 202:
				return BoxError.fileNotReady
			case 200 ... 299:
				return nil
			default:
				return apiError(of: response, outcome)
			}
		}
	}

	private static func apiError(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome) -> BoxError {
		let errorResponse = outcome.data.flatMap { try? JSONDecoder().decode(BoxErrorResponse.self, from: $0) }
		return .apiError(statusCode: response.statusCode, code: errorResponse?.code, message: errorResponse?.message)
	}
}
