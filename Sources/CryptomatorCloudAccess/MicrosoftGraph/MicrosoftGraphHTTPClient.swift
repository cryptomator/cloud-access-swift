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

 The upload URL of an upload session is pre-authenticated, possibly by a token in its path, and often on another host. Its `PUT`s therefore carry no `Authorization` header, a 401 of theirs is final, and their URLs are logged only as origins. So are the URLs of downloads, which redirect to a pre-authenticated URL on a content host whose path names the account. The bodies of metadata responses and uploads aren't logged, because their items carry pre-authenticated download URLs and the accounts' emails. Thrown errors never contain a request URL.
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

	/// Moves the body of a 2xx response to `stagingURL`, at which no item may exist, and returns the response, whatever its status.
	func download(_ request: URLRequest, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> HTTPURLResponse {
		let handler = HTTPClientSupport.downloadHandler(movingTo: stagingURL, maxErrorBodyLength: HTTPClientSupport.maxErrorBodyLength)
		let (response, _) = try await send(request, urlLogging: .originOnly, progress: progress) { request, isFirstAttempt in
			try await self.session.download(request, route: .transfer, handler: handler, bodyLogging: .logged, urlLogging: .originOnly, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
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

	// MARK: - Errors

	static func error(forStatusCode statusCode: Int) -> Error {
		switch statusCode {
		case 401, 403:
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
