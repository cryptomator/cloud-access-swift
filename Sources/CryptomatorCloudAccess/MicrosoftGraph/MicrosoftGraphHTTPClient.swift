//
//  MicrosoftGraphHTTPClient.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Sends Microsoft Graph requests for one account on a `SplitURLSession`.

 Requests are sent by a `BearerRequestSender`. A 429, 503 and 504 are retried. A 500 and 502 are retried only for a `GET` and the `PUT` of an upload session, because Graph may have applied a mutation that it answered with one. An upload session discards a chunk that failed, so its `PUT` is safe to repeat. Transient transport errors are retried only for a `GET`, because a repeated mutation could be applied twice.

 The upload URL of an upload session is pre-authenticated, possibly by a token in its path, and often on another host. Its `PUT`s therefore carry no `Authorization` header, a 401 of theirs is final, and their URLs are logged only as origins. The same holds for downloads from an item's pre-authenticated download URL, on a content host whose path names the account. Downloads through Graph redirect to such a URL, which the log shows only as its origin, because it is on another host than the request.

 The bodies of downloads aren't logged, because a content host's error body may echo the URL. Neither are those of metadata responses and uploads, because their items carry pre-authenticated download URLs and the accounts' emails. Thrown errors never contain a request URL.
 */
final class MicrosoftGraphHTTPClient: Sendable {
	private static let logLabel = "MicrosoftGraphHTTPClient"
	private static let retriedStatusCodes: Set<Int> = [429, 503, 504]
	/// Statuses after which Graph may have applied the request.
	private static let retriedServerErrorStatusCodes: Set<Int> = [500, 502]

	private let session: SplitURLSession
	private let sender: BearerRequestSender

	init(tokenSource: any BearerTokenSource, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks(), registry: BackgroundURLSessionRegistry = .shared, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
		self.session = SplitURLSession(configuration: configuration, metadataConfiguration: metadataConfiguration, hooks: hooks, registry: registry)
		self.sender = BearerRequestSender(tokenSource: tokenSource, logLabel: MicrosoftGraphHTTPClient.logLabel, sleep: sleep)
	}

	static func foreground(tokenSource: any BearerTokenSource) -> MicrosoftGraphHTTPClient {
		return MicrosoftGraphHTTPClient(tokenSource: tokenSource, configuration: foregroundConfiguration(), metadataConfiguration: nil)
	}

	/// Creates a client whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.
	static func background(tokenSource: any BearerTokenSource, sessionIdentifier: String, sharedContainerIdentifier: String?) -> MicrosoftGraphHTTPClient {
		return MicrosoftGraphHTTPClient(tokenSource: tokenSource, configuration: backgroundConfiguration(sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier), metadataConfiguration: foregroundConfiguration())
	}

	static func foregroundConfiguration() -> URLSessionConfiguration {
		return HTTPClientSupport.hardened(.default)
	}

	static func backgroundConfiguration(sessionIdentifier: String, sharedContainerIdentifier: String?) -> URLSessionConfiguration {
		return HTTPClientSupport.hardenedBackground(identifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
	}

	// MARK: - Operations

	func item(at address: MicrosoftGraphAPI.ItemAddress) async throws -> MicrosoftGraphAPI.DriveItem {
		let url = try MicrosoftGraphHTTPClient.apiURL(address.percentEncodedPath, parameters: [("$select", MicrosoftGraphAPI.DriveItem.selectedFields)])
		return try await MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: dataExpectingOK(HTTPClientSupport.request("GET", url)))
	}

	/// Sends no `$select`, so that the response carries `@microsoft.graph.downloadUrl`.
	func itemWithDownloadURL(at address: MicrosoftGraphAPI.ItemAddress) async throws -> MicrosoftGraphAPI.DriveItem {
		let url = try MicrosoftGraphHTTPClient.apiURL(address.percentEncodedPath)
		return try await MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: dataExpectingOK(HTTPClientSupport.request("GET", url)))
	}

	func children(of address: MicrosoftGraphAPI.ItemAddress, pageSize: Int) async throws -> MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.DriveItem> {
		let url = try MicrosoftGraphHTTPClient.apiURL("\(address.percentEncodedPath)/children", parameters: [("$top", String(pageSize)), ("$select", MicrosoftGraphAPI.DriveItem.selectedFields)])
		return try await children(at: url)
	}

	/// Sends the `@odata.nextLink` of a listing's page as it is.
	func children(nextLink: URL) async throws -> MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.DriveItem> {
		return try await children(at: nextLink)
	}

	private func children(at url: URL) async throws -> MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.DriveItem> {
		return try await MicrosoftGraphAPI.decode(MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.DriveItem>.self, from: dataExpectingOK(HTTPClientSupport.request("GET", url)))
	}

	func child(named name: String, in address: MicrosoftGraphAPI.ItemAddress) async throws -> MicrosoftGraphAPI.DriveItem {
		let url = try MicrosoftGraphHTTPClient.apiURL("\(address.percentEncodedPath):/\(HTTPClientSupport.pathComponent(name)):", parameters: [("$select", MicrosoftGraphAPI.DriveItem.selectedFields)])
		return try await MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: dataExpectingOK(HTTPClientSupport.request("GET", url)))
	}

	func createFolder(named name: String, in address: MicrosoftGraphAPI.ItemAddress) async throws -> MicrosoftGraphAPI.DriveItem {
		let request = try HTTPClientSupport.request("POST", MicrosoftGraphHTTPClient.apiURL("\(address.percentEncodedPath)/children"), json: MicrosoftGraphAPI.DriveItemRequestBody(name: name, folder: MicrosoftGraphAPI.Folder()))
		let (response, data) = try await data(request)
		guard response.statusCode == 201 || response.statusCode == 200 else {
			throw MicrosoftGraphHTTPClient.error(forStatusCode: response.statusCode)
		}
		return try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: data)
	}

	func delete(_ address: MicrosoftGraphAPI.ItemAddress) async throws {
		let (response, _) = try await data(HTTPClientSupport.request("DELETE", MicrosoftGraphHTTPClient.apiURL(address.percentEncodedPath)))
		guard response.statusCode == 204 else {
			throw MicrosoftGraphHTTPClient.error(forStatusCode: response.statusCode)
		}
	}

	/// A `DecodingError` means that Graph accepted the move.
	func move(_ address: MicrosoftGraphAPI.ItemAddress, named name: String, toParentID parentID: String, parentDriveID: String?) async throws -> MicrosoftGraphAPI.DriveItem {
		let body = MicrosoftGraphAPI.DriveItemRequestBody(name: name, parentReference: MicrosoftGraphAPI.ItemReference(id: parentID, driveId: parentDriveID))
		let request = try HTTPClientSupport.request("PATCH", MicrosoftGraphHTTPClient.apiURL(address.percentEncodedPath), json: body)
		return try await MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: dataExpectingOK(request))
	}

	// MARK: - Transfers

	/// Downloads the content of the file through Graph to `stagingURL`, at which no item may exist.
	func downloadContent(of address: MicrosoftGraphAPI.ItemAddress, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws {
		let request = try HTTPClientSupport.request("GET", MicrosoftGraphHTTPClient.apiURL("\(address.percentEncodedPath)/content"))
		let response = try await download(request, to: stagingURL, progress: progress, onTaskCreation: onTaskCreation)
		guard response.statusCode == 200 else {
			throw MicrosoftGraphHTTPClient.error(forStatusCode: response.statusCode)
		}
	}

	/// Downloads from an item's pre-authenticated download URL without the access token to `stagingURL`, and returns the response, whatever its status.
	func download(fromDownloadURL downloadURL: URL, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> HTTPURLResponse {
		return try await download(HTTPClientSupport.request("GET", downloadURL), authorization: .none, to: stagingURL, progress: progress, onTaskCreation: onTaskCreation)
	}

	/**
	 Creates an upload session for the file of the name in the folder, which the upload creates or replaces.

	 - Returns: The upload URL of the session.
	 - Throws: `MicrosoftGraphError.unexpectedContent` if the response carries no HTTPS upload URL with a host, because that URL is a credential and receives the file's content.
	 */
	func createUploadSession(named name: String, in address: MicrosoftGraphAPI.ItemAddress) async throws -> URL {
		let url = try MicrosoftGraphHTTPClient.apiURL("\(address.percentEncodedPath):/\(HTTPClientSupport.pathComponent(name)):/createUploadSession")
		let uploadSession = try await MicrosoftGraphAPI.decode(MicrosoftGraphAPI.UploadSession.self, from: dataExpectingOK(HTTPClientSupport.request("POST", url)))
		guard let uploadURL = MicrosoftGraphAPI.preAuthenticatedURL(uploadSession.uploadUrl) else {
			throw MicrosoftGraphError.unexpectedContent
		}
		return uploadURL
	}

	/**
	 Uploads one chunk of a file to the upload URL of an upload session, from a file that holds just that chunk.

	 - Parameter offset: The offset of the chunk's first byte in the file.
	 - Returns: The uploaded item once the last chunk arrived, or `nil` if the upload continues.
	 - Throws: `MicrosoftGraphError.unexpectedHTTPStatusCode` for a 401 or a 404, rather than `unauthorized` or `itemNotFound`. The upload URL is pre-authenticated, so signing in again can't fix its 401. Its 404 concerns the upload session, e.g., an expired one, not the item.
	 */
	// swiftlint:disable:next function_parameter_count
	func uploadChunk(to uploadURL: URL, fromFile chunkFileURL: URL, offset: Int, length: Int, totalLength: Int, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> MicrosoftGraphAPI.DriveItem? {
		var request = URLRequest(url: uploadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60.0)
		request.httpMethod = "PUT"
		request.setValue("bytes \(offset)-\(offset + length - 1)/\(totalLength)", forHTTPHeaderField: "Content-Range")
		let (response, data) = try await upload(request, fromFile: chunkFileURL, progress: progress, onTaskCreation: onTaskCreation)
		switch response.statusCode {
		case 202:
			return nil
		case 200, 201:
			return try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: data)
		case 401, 404:
			throw MicrosoftGraphError.unexpectedHTTPStatusCode(code: response.statusCode)
		default:
			throw MicrosoftGraphHTTPClient.error(forStatusCode: response.statusCode)
		}
	}

	// MARK: - Discovery

	/// - Parameter percentEncodedSitePath: The site URL's percent-encoded path, appended to the request's path without further escaping.
	func site(hostName: String, percentEncodedSitePath: String) async throws -> MicrosoftGraphAPI.Site {
		let url = try MicrosoftGraphHTTPClient.apiURL("/sites/\(HTTPClientSupport.pathComponent(hostName)):\(percentEncodedSitePath)")
		return try await MicrosoftGraphAPI.decode(MicrosoftGraphAPI.Site.self, from: dataExpectingOK(HTTPClientSupport.request("GET", url)))
	}

	func drives(ofSite siteID: String) async throws -> MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.Drive> {
		let url = try MicrosoftGraphHTTPClient.apiURL("/sites/\(HTTPClientSupport.pathComponent(siteID))/drives")
		return try await MicrosoftGraphAPI.decode(MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.Drive>.self, from: dataExpectingOK(HTTPClientSupport.request("GET", url)))
	}

	func drive(id: String) async throws -> MicrosoftGraphAPI.Drive {
		let url = try MicrosoftGraphHTTPClient.apiURL("/drives/\(HTTPClientSupport.pathComponent(id))")
		return try await MicrosoftGraphAPI.decode(MicrosoftGraphAPI.Drive.self, from: dataExpectingOK(HTTPClientSupport.request("GET", url)))
	}

	// MARK: - Requests

	/**
	 Sends a request on the metadata session and returns the body of its 200 response.

	 - Throws: The error of `error(forStatusCode:)` for any other status.
	 */
	func dataExpectingOK(_ request: URLRequest) async throws -> Data {
		let (response, data) = try await data(request)
		guard response.statusCode == 200 else {
			throw MicrosoftGraphHTTPClient.error(forStatusCode: response.statusCode)
		}
		return data
	}

	/// Sends a request on the metadata session and returns its response, whatever its status.
	func data(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
		let (response, outcome) = try await send(request, urlLogging: .redacted) { request, _ in
			try await self.session.data(request, bodyLimit: HTTPClientSupport.maxMetadataBodyLength, bodyLogging: .omitted)
		}
		return (response, outcome.data ?? Data())
	}

	/**
	 Moves the body of a 2xx response to `stagingURL`, at which no item may exist, and returns the response, whatever its status.

	 - Parameter authorization: `.none` for the pre-authenticated download URL of an item, which is a credential as a whole and therefore logged by its origin only.
	 */
	func download(_ request: URLRequest, authorization: BearerRequestSender.Authorization = .bearer, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> HTTPURLResponse {
		let handler = HTTPClientSupport.downloadHandler(movingTo: stagingURL, maxErrorBodyLength: HTTPClientSupport.maxErrorBodyLength)
		let urlLogging: HTTPDebugLogger.URLLogging = authorization == .none ? .originOnly : .redacted
		let (response, _) = try await send(request, authorization: authorization, urlLogging: urlLogging, progress: progress) { request, isFirstAttempt in
			try await self.session.download(request, route: .transfer, handler: handler, bodyLogging: .omitted, urlLogging: urlLogging, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
		return response
	}

	/// Sends a request to the upload URL of an upload session, without an `Authorization` header, and returns its response, whatever its status.
	func upload(_ request: URLRequest, fromFile fileURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> (HTTPURLResponse, Data) {
		let (response, outcome) = try await send(request, authorization: .none, urlLogging: .originOnly, progress: progress) { request, isFirstAttempt in
			try await self.session.upload(request, fromFile: fileURL, bodyLimit: HTTPClientSupport.maxErrorBodyLength, bodyLogging: .omitted, urlLogging: .originOnly, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
		return (response, outcome.data ?? Data())
	}

	private func send(_ request: URLRequest, authorization: BearerRequestSender.Authorization = .bearer, urlLogging: HTTPDebugLogger.URLLogging, progress: Progress? = nil, attempt: (URLRequest, _ isFirstAttempt: Bool) async throws -> SplitURLSession.Outcome) async throws -> (HTTPURLResponse, SplitURLSession.Outcome) {
		let isGET = (request.httpMethod ?? "GET") == "GET"
		let retriesServerErrors = isGET || authorization == .none
		let policy = RetryPolicy(retriesTransportErrors: isGET, isRetryable: { response, _ in
			MicrosoftGraphHTTPClient.retriedStatusCodes.contains(response.statusCode) || retriesServerErrors && MicrosoftGraphHTTPClient.retriedServerErrorStatusCodes.contains(response.statusCode)
		}, failure: { response, _ in
			MicrosoftGraphError.unexpectedHTTPStatusCode(code: response.statusCode)
		})
		return try await sender.send(request, authorization: authorization, urlLogging: urlLogging, policy: policy, progress: progress, attempt: attempt)
	}

	private static func apiURL(_ path: String, parameters: [(String, String)] = []) throws -> URL {
		return try HTTPClientSupport.url(host: MicrosoftGraphAPI.host, percentEncodedPath: "/v1.0\(path)", parameters: parameters)
	}

	// MARK: - Errors

	static func error(forStatusCode statusCode: Int) -> Error {
		switch statusCode {
		case 401:
			// Graph answers a rejected token with 401. A 403 concerns the item, the site or a policy, and Graph's `accessDenied` doesn't tell these apart from a missing scope, so it passes through raw.
			return CloudProviderError.unauthorized
		case 404:
			return CloudProviderError.itemNotFound
		case 507:
			return CloudProviderError.quotaInsufficient
		default:
			return MicrosoftGraphError.unexpectedHTTPStatusCode(code: statusCode)
		}
	}
}
