//
//  PCloudClient.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Sends pCloud API requests for one account on a `SplitURLSession`.

 Every call is a form-encoded `POST` to the API host of the login, with the login's access token in its body. Uploads send the token in the query, and downloads send only the download tag of their file link as a cookie. Reads are retried after transient failures; mutations, uploads and downloads aren't.

 Log lines omit request and response bodies, which carry the access token, the file-link path and the download tag. They show a file-link URL only as its origin. Thrown errors never contain a request URL.
 */
final class PCloudClient: Sendable {
	private static let maxRetryCount = 3
	private static let formatParameters = [("iconformat", "id"), ("timeformat", "timestamp")]

	private let tokenSource: any PCloudTokenSource
	private let session: SplitURLSession
	private let sleep: @Sendable (Duration) async throws -> Void

	init(tokenSource: any PCloudTokenSource, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks(), registry: BackgroundURLSessionRegistry = .shared, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
		self.tokenSource = tokenSource
		self.session = SplitURLSession(configuration: configuration, metadataConfiguration: metadataConfiguration, hooks: hooks, registry: registry)
		self.sleep = sleep
	}

	static func foreground(tokenSource: any PCloudTokenSource) -> PCloudClient {
		return PCloudClient(tokenSource: tokenSource, configuration: HTTPClientSupport.hardened(.default), metadataConfiguration: nil)
	}

	/// Creates a client whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.
	static func background(tokenSource: any PCloudTokenSource, sessionIdentifier: String, sharedContainerIdentifier: String?) -> PCloudClient {
		return PCloudClient(tokenSource: tokenSource, configuration: backgroundConfiguration(sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier), metadataConfiguration: HTTPClientSupport.hardened(.default))
	}

	static func backgroundConfiguration(sessionIdentifier: String, sharedContainerIdentifier: String?) -> URLSessionConfiguration {
		return HTTPClientSupport.hardenedBackground(identifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
	}

	// MARK: - Operations

	func userInfoEmail() async throws -> String {
		return try await PCloudJSON.email(in: call("userinfo", parameters: [], isIdempotent: true))
	}

	/**
	 Downloads the listing of the folder to `fileURL`, where it stays after it was read once in full.

	 The listing has no paging, so its body holds the whole folder, however large. It is therefore streamed to the file and read in chunks, and its children are read from the file later.

	 - Throws: `PCloudError.unexpectedContent` if the listing has no folder metadata that `JSONDecoder` can decode, or has `contents` that is neither `null` nor an array of objects.
	 */
	func listFolder(_ folderID: UInt64, to fileURL: URL) async throws -> PCloudFolderListing {
		let summary = try await perform("listfolder", parameters: [("folderid", String(folderID)), ("recursive", "0")] + PCloudClient.formatParameters, isIdempotent: true, send: { request in
			// A retried attempt's download is moved to the same file, at which no item may exist.
			try? FileManager.default.removeItem(at: fileURL)
			return try await self.session.download(request, route: .metadata, handler: HTTPClientSupport.downloadHandler(movingTo: fileURL, maxErrorBodyLength: HTTPClientSupport.maxErrorBodyLength), bodyLogging: .omitted, urlLogging: .redacted, progress: nil, cancelsBeforeResume: false, onTaskCreation: nil)
		}, read: PCloudClient.successfulListing(of:))
		guard summary.metadata == .object, summary.contents != .other else {
			throw PCloudError.unexpectedContent
		}
		return try PCloudFolderListing(folder: PCloudJSON.folder(fromFields: summary.folderFields), hasContents: summary.contents == .objects, fileURL: fileURL)
	}

	func stat(fileID: UInt64) async throws -> PCloudMetadata {
		return try await PCloudJSON.metadata(in: call("stat", parameters: [("fileid", String(fileID))] + PCloudClient.formatParameters, isIdempotent: true))
	}

	/// - Throws: `PCloudError.fileLinkNotFound` if the link has no host.
	func getFileLink(fileID: UInt64) async throws -> PCloudFileLink {
		let fileLink = try await PCloudJSON.fileLink(in: call("getfilelink", parameters: [("fileid", String(fileID)), ("timeformat", "timestamp")], isIdempotent: true))
		guard !fileLink.hosts.isEmpty else {
			throw PCloudError.fileLinkNotFound
		}
		return fileLink
	}

	func createFolder(name: String, parentID: UInt64) async throws -> PCloudMetadata {
		return try await PCloudJSON.metadata(in: call("createfolder", parameters: [("name", name), ("folderid", String(parentID))] + PCloudClient.formatParameters, isIdempotent: false))
	}

	func renameFolder(_ folderID: UInt64, toParent parentID: UInt64, name: String) async throws -> PCloudMetadata {
		return try await PCloudJSON.metadata(in: call("renamefolder", parameters: [("folderid", String(folderID)), ("tofolderid", String(parentID)), ("toname", name)] + PCloudClient.formatParameters, isIdempotent: false))
	}

	func deleteFolderRecursive(_ folderID: UInt64) async throws {
		_ = try await call("deletefolderrecursive", parameters: [("folderid", String(folderID))], isIdempotent: false)
	}

	func renameFile(_ fileID: UInt64, toParent parentID: UInt64, name: String) async throws -> PCloudMetadata {
		return try await PCloudJSON.metadata(in: call("renamefile", parameters: [("fileid", String(fileID)), ("tofolderid", String(parentID)), ("toname", name)] + PCloudClient.formatParameters, isIdempotent: false))
	}

	func deleteFile(_ fileID: UInt64) async throws {
		_ = try await call("deletefile", parameters: [("fileid", String(fileID))] + PCloudClient.formatParameters, isIdempotent: false)
	}

	// MARK: - Transfers

	/// Uploads the file as `name` into the folder, replacing a file of that name.
	func upload(fromFile fileURL: URL, parentID: UInt64, name: String, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> PCloudMetadata {
		let login = try tokenSource.login()
		let parameters = [("access_token", login.accessToken), ("folderid", String(parentID)), ("filename", name), ("nopartial", "1")] + PCloudClient.formatParameters
		var request = try HTTPClientSupport.request("POST", HTTPClientSupport.url(host: login.apiHost, percentEncodedPath: "/uploadfile", parameters: parameters))
		request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
		let outcome = try await session.upload(request, fromFile: fileURL, bodyLimit: HTTPClientSupport.maxErrorBodyLength, bodyLogging: .omitted, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: onTaskCreation)
		do {
			return try PCloudJSON.uploadedMetadata(in: PCloudClient.successfulBody(of: outcome))
		} catch {
			PCloudClient.logFailure(of: "uploadfile", with: error)
			throw PCloudClient.converted(error)
		}
	}

	/// Downloads the file of the link to `stagingURL`, at which no item may exist.
	func download(_ fileLink: PCloudFileLink, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws {
		var components = URLComponents()
		components.scheme = "https"
		components.host = fileLink.hosts.first
		components.path = fileLink.path
		guard let url = components.url else {
			throw PCloudError.unexpectedContent
		}
		var request = URLRequest(url: url)
		request.setValue("dwltag=\(fileLink.dwltag)", forHTTPHeaderField: "Cookie")
		let outcome = try await session.download(request, route: .transfer, handler: HTTPClientSupport.downloadHandler(movingTo: stagingURL, maxErrorBodyLength: HTTPClientSupport.maxErrorBodyLength), bodyLogging: .omitted, urlLogging: .originOnly, progress: progress, cancelsBeforeResume: true, onTaskCreation: onTaskCreation)
		do {
			let httpResponse = try HTTPClientSupport.httpResponse(of: outcome)
			guard (200 ... 299).contains(httpResponse.statusCode), case .file = outcome.body else {
				_ = try PCloudClient.successfulBody(of: outcome)
				throw PCloudError.unexpectedHTTPStatusCode(code: httpResponse.statusCode)
			}
		} catch {
			PCloudClient.logFailure(of: "file link download", with: error)
			throw PCloudClient.converted(error)
		}
	}

	// MARK: - Requests

	/**
	 Calls the API method and returns the body of its successful result.

	 An idempotent call is retried up to three times if its failure is transient. A transient failure is a connection that couldn't be made, dropped or timed out (including DNS and TLS failures), a throttling or server status, a 2xx response that isn't a pCloud result, or an API code for too many actions or an internal error. A retry waits for the response's `Retry-After`, capped at 60 seconds, or else for a random exponential delay.

	 Every attempt reads the login again.

	 A cancelled task stops the call instead of retrying it, also during the wait before a retry. The first attempt is sent and a running attempt finishes either way.
	 */
	func call(_ command: String, parameters: [(String, String)], isIdempotent: Bool) async throws -> Data {
		return try await perform(command, parameters: parameters, isIdempotent: isIdempotent, send: { request in
			try await self.session.data(request, bodyLimit: HTTPClientSupport.maxMetadataBodyLength, bodyLogging: .omitted)
		}, read: PCloudClient.successfulBody(of:))
	}

	/// Sends the API method's form `POST` with `send` and reads its outcome with `read`, retrying as `call(_:parameters:isIdempotent:)` does.
	private func perform<T>(_ command: String, parameters: [(String, String)], isIdempotent: Bool, send: (URLRequest) async throws -> SplitURLSession.Outcome, read: (SplitURLSession.Outcome) throws -> T) async throws -> T {
		var retryCount = 0
		while true {
			let login = try tokenSource.login()
			var request = try HTTPClientSupport.request("POST", HTTPClientSupport.url(host: login.apiHost, percentEncodedPath: "/\(command)", parameters: []))
			request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
			request.httpBody = Data(HTTPClientSupport.formEncoded([("access_token", login.accessToken)] + parameters).utf8)
			let outcome = try await send(request)
			let failure: Error
			do {
				return try read(outcome)
			} catch {
				failure = error
			}
			PCloudClient.logFailure(of: command, with: failure)
			// The retry decision reads the raw failure, because most transient connection errors are also network connection errors.
			guard isIdempotent, retryCount < PCloudClient.maxRetryCount, PCloudClient.isTransient(failure) else {
				throw PCloudClient.converted(failure)
			}
			retryCount += 1
			try Task.checkCancellation()
			try await sleep(HTTPClientSupport.retryDelay(of: outcome, retry: retryCount))
		}
	}

	// MARK: - Outcomes

	/// Returns the body of a successful pCloud result, and otherwise throws the result's error, whatever the HTTP status. A body that isn't a pCloud result throws `PCloudError.unexpectedHTTPStatusCode` for a non-2xx status and `PCloudError.unexpectedContent` for a 2xx status.
	private static func successfulBody(of outcome: SplitURLSession.Outcome) throws -> Data {
		let httpResponse = try HTTPClientSupport.httpResponse(of: outcome)
		do {
			return try PCloudJSON.result(of: outcome.data ?? Data())
		} catch PCloudError.unexpectedContent where !(200 ... 299).contains(httpResponse.statusCode) {
			throw PCloudError.unexpectedHTTPStatusCode(code: httpResponse.statusCode)
		}
	}

	/**
	 Reads a downloaded listing in full and judges its `result` and `error` as `successfulBody(of:)` judges a body, without holding the listing in memory.

	 An `error` string over 4 KiB is read as no message, whatever its content. A non-2xx status throws even with a successful result, because its body isn't the listing.
	 */
	private static func successfulListing(of outcome: SplitURLSession.Outcome) throws -> PCloudListingReader.Summary {
		let httpResponse = try HTTPClientSupport.httpResponse(of: outcome)
		guard (200 ... 299).contains(httpResponse.statusCode), case let .file(fileURL) = outcome.body else {
			_ = try successfulBody(of: outcome)
			throw PCloudError.unexpectedHTTPStatusCode(code: httpResponse.statusCode)
		}
		let summary = try PCloudListingReader.validate(fileAt: fileURL)
		guard case let .number(result) = summary.result else {
			throw PCloudError.unexpectedContent
		}
		var resultBody = Data(#"{"result":"#.utf8) + result
		switch summary.error {
		case let .string(error):
			resultBody += Data(#","error":"#.utf8) + error
		case .absent, .null, .oversizedString:
			break
		case .other:
			throw PCloudError.unexpectedContent
		}
		// `JSONDecoder` reads the number and the message, so that they are read as in the body of any other method.
		_ = try PCloudJSON.result(of: resultBody + Data("}".utf8))
		return summary
	}

	private static func isTransient(_ error: Error) -> Bool {
		switch error {
		case let urlError as URLError:
			return HTTPClientSupport.isTransient(urlError)
		case let PCloudError.unexpectedHTTPStatusCode(statusCode):
			return statusCode == 429 || (500 ... 599).contains(statusCode)
		case PCloudError.unexpectedContent:
			return true
		case let PCloudError.apiError(code, _):
			// Too many actions, or an internal error.
			return code == 4010 || (5000 ... 5999).contains(code)
		default:
			return false
		}
	}

	/// Maps connectivity errors here rather than in the provider, because `PCloudCredential.getUsername()` calls the client directly.
	private static func converted(_ error: Error) -> Error {
		return isNetworkConnectionError(error) ? CloudProviderError.noInternetConnection : error
	}

	private static func logFailure(of command: String, with error: Error) {
		CloudAccessDDLogDebug("PCloudClient: \(command) failed with \(error)")
	}
}
