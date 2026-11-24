//
//  BoxClient.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Sends Box API requests for one account on a `SplitURLSession`.

 Requests are sent by a `BearerRequestSender`. A 429, a server error and a 202 with `Retry-After` are retried, mutations included. Such a 202 means that a download or an upload isn't processed yet. Transient transport errors are retried only for a `GET`, because a repeated mutation could be applied twice.

 The bodies of metadata responses and of single-request uploads aren't logged, because they name the account, e.g., by its login email. Downloads redirect to a pre-authenticated URL on another host, which the log shows only as its origin. Thrown errors never contain a request URL.
 */
final class BoxClient: SplitSessionClient, Sendable {
	typealias TokenSource = any BearerTokenSource

	private static let logLabel = "BoxClient"
	private static let listingFields = "name,size,modified_at"
	/// Box answers a recursive folder delete only once it is done, and sends nothing before. A delete takes about 130 s per 1,000 items (measured in November 2026), and Box gives up with a 503 after 600 s. The timeout exceeds those 600 s, because a shorter one would fail a delete that Box completes.
	private static let recursiveDeleteTimeout: TimeInterval = 660

	private let transport: BearerHTTPTransport

	init(tokenSource: any BearerTokenSource, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks(), registry: BackgroundURLSessionRegistry = .shared, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
		self.transport = BearerHTTPTransport(tokenSource: tokenSource, logLabel: BoxClient.logLabel, configuration: configuration, metadataConfiguration: metadataConfiguration, hooks: hooks, registry: registry, sleep: sleep)
	}

	// MARK: - Operations

	/// - Parameter fields: The fields that the response carries besides `type`, `id` and `etag`, or `nil` for Box's standard fields.
	func file(id: String, fields: String? = nil) async throws -> BoxEntry {
		let parameters = fields.map { [("fields", $0)] } ?? []
		return try await BoxJSON.decode(BoxEntry.self, from: data(HTTPClientSupport.request("GET", BoxClient.apiURL("/files/\(HTTPClientSupport.pathComponent(id))", parameters: parameters))))
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
		var request = try HTTPClientSupport.request("DELETE", BoxClient.apiURL("/folders/\(HTTPClientSupport.pathComponent(id))", parameters: [("recursive", "true")]))
		request.timeoutInterval = BoxClient.recursiveDeleteTimeout
		_ = try await data(request)
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
		let (response, outcome) = try await transport.download(request, bodyLogging: .omitted, handler: BoxClient.downloadHandler(movingTo: stagingURL), policy: BoxClient.policy(for: request), progress: progress, onTaskCreation: onTaskCreation)
		_ = try BoxClient.successfulBody(of: response, outcome, for: request)
		guard case .file = outcome.body else {
			throw BoxError.unexpectedContent
		}
	}

	/// Uploads the file as `name` into the folder in a single request.
	func uploadNewFile(from fileURL: URL, name: String, parentID: String, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> BoxFiles {
		return try await uploadMultipart(BoxClient.uploadURL("/files/content"), attributes: BoxItemRequest(name: name, parent: BoxParentReference(id: parentID)), from: fileURL, progress: progress, onTaskCreation: onTaskCreation)
	}

	/// Uploads the file as a new version of an existing file in a single request. It sends no name, because Box would rename the file to it, which undoes a move that landed after the file was resolved.
	func uploadFileVersion(from fileURL: URL, fileID: String, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> BoxFiles {
		return try await uploadMultipart(BoxClient.uploadURL("/files/\(HTTPClientSupport.pathComponent(fileID))/content"), attributes: BoxVersionAttributes(), from: fileURL, progress: progress, onTaskCreation: onTaskCreation)
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
		let (response, outcome) = try await transport.upload(request, fromFile: partFileURL, bodyLogging: .logged, policy: BoxClient.policy(for: request), progress: progress, onTaskCreation: nil)
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
		var request = try HTTPClientSupport.request("POST", HTTPClientSupport.uploadSessionURL(url, onDomain: "box.com", orThrow: BoxError.unexpectedContent), json: BoxCommitRequest(parts: parts))
		request.setValue(digest, forHTTPHeaderField: "digest")
		return try await BoxJSON.decode(BoxFiles.self, from: data(request))
	}

	// MARK: - Requests

	/// Sends a request on the metadata session and returns the body of its successful response.
	private func data(_ request: URLRequest) async throws -> Data {
		let (response, outcome) = try await transport.data(request, bodyLogging: .omitted, policy: BoxClient.policy(for: request))
		return try BoxClient.successfulBody(of: response, outcome, for: request)
	}

	private static func policy(for request: URLRequest) -> RetryPolicy {
		return RetryPolicy(retriesTransportErrors: request.httpMethod == "GET", isRetryable: { response, _ in BoxClient.isRetryable(response) }, failure: { response, outcome in BoxClient.apiError(of: response, outcome, for: request) })
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

	private func uploadMultipart(_ url: URL, attributes: some Encodable, from fileURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> BoxFiles {
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
		let (response, outcome) = try await transport.upload(request, fromFile: bodyFileURL, bodyLogging: .omitted, policy: BoxClient.policy(for: request), progress: progress, onTaskCreation: onTaskCreation)
		return try BoxJSON.decode(BoxFiles.self, from: BoxClient.successfulBody(of: response, outcome, for: request))
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
	private static func successfulBody(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome, for request: URLRequest) throws -> Data {
		return try HTTPClientSupport.successfulBody(of: response, outcome, for: request, urlLogging: .redacted, label: logLabel) { response, outcome in
			switch response.statusCode {
			case 202:
				return BoxError.fileNotReady
			case 200 ... 299:
				return nil
			default:
				return apiError(of: response, outcome, for: request)
			}
		}
	}

	private static func apiError(of response: HTTPURLResponse, _ outcome: SplitURLSession.Outcome, for request: URLRequest) -> BoxError {
		let errorResponse = outcome.data.flatMap { try? JSONDecoder().decode(BoxErrorResponse.self, from: $0) }
		let message = HTTPClientSupport.hasRequestOrigin(response, of: request) ? errorResponse?.message : nil
		return .apiError(statusCode: response.statusCode, code: errorResponse?.code ?? challengeError(of: response), message: message)
	}

	/// The `error` parameter of the response's `WWW-Authenticate` challenge. Box can answer a 403 `insufficient_scope` without a body and name the code only there (box-python-sdk issue #599).
	private static func challengeError(of response: HTTPURLResponse) -> String? {
		guard let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate"), let match = challenge.firstMatch(of: /(?:^|[\s,])error="?([^",\s]+)/) else {
			return nil
		}
		return String(match.1)
	}
}
