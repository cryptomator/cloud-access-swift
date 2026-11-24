//
//  BearerHTTPTransport.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 21.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Sends the requests of a bearer client through a `BearerRequestSender` on a `SplitURLSession`.

 Each method returns the response of the final attempt and its outcome, whatever its status, so that the client checks success itself. `onTaskCreation` gets only the first attempt's task.

 Metadata requests read at most `HTTPClientSupport.maxMetadataBodyLength`, and the responses of uploads at most `HTTPClientSupport.maxErrorBodyLength`. A request that carries the token logs its URL redacted, and a transfer to a pre-authenticated URL only by its origin.
 */
struct BearerHTTPTransport: Sendable {
	/// The underlying session, for requests that do their own authorization and retries instead of going through the sender.
	let session: SplitURLSession
	private let sender: BearerRequestSender

	init(tokenSource: any BearerTokenSource, logLabel: String, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks, registry: BackgroundURLSessionRegistry, sleep: @escaping @Sendable (Duration) async throws -> Void) {
		self.session = SplitURLSession(configuration: configuration, metadataConfiguration: metadataConfiguration, hooks: hooks, registry: registry)
		self.sender = BearerRequestSender(tokenSource: tokenSource, logLabel: logLabel, sleep: sleep)
	}

	/// Sends a request with the token on the metadata session.
	func data(_ request: URLRequest, bodyLogging: HTTPDebugLogger.BodyLogging, policy: RetryPolicy) async throws -> (HTTPURLResponse, SplitURLSession.Outcome) {
		return try await sender.send(request, urlLogging: .redacted, policy: policy) { request, _ in
			try await session.data(request, bodyLimit: HTTPClientSupport.maxMetadataBodyLength, bodyLogging: bodyLogging)
		}
	}

	/// Downloads on the transfer session.
	// swiftlint:disable:next function_parameter_count
	func download(_ request: URLRequest, authorization: BearerRequestSender.Authorization = .bearer, bodyLogging: HTTPDebugLogger.BodyLogging, handler: @escaping SplitURLSession.DownloadHandler, policy: RetryPolicy, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> (HTTPURLResponse, SplitURLSession.Outcome) {
		let urlLogging = BearerHTTPTransport.urlLogging(of: authorization)
		return try await sender.send(request, authorization: authorization, urlLogging: urlLogging, policy: policy, progress: progress) { request, isFirstAttempt in
			try await session.download(request, route: .transfer, handler: handler, bodyLogging: bodyLogging, urlLogging: urlLogging, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
	}

	/// Uploads from a file on the transfer session.
	// swiftlint:disable:next function_parameter_count
	func upload(_ request: URLRequest, fromFile fileURL: URL, authorization: BearerRequestSender.Authorization = .bearer, bodyLogging: HTTPDebugLogger.BodyLogging, policy: RetryPolicy, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> (HTTPURLResponse, SplitURLSession.Outcome) {
		let urlLogging = BearerHTTPTransport.urlLogging(of: authorization)
		return try await sender.send(request, authorization: authorization, urlLogging: urlLogging, policy: policy, progress: progress) { request, isFirstAttempt in
			try await session.upload(request, fromFile: fileURL, bodyLimit: HTTPClientSupport.maxErrorBodyLength, bodyLogging: bodyLogging, urlLogging: urlLogging, progress: progress, cancelsBeforeResume: true, onTaskCreation: isFirstAttempt ? onTaskCreation : nil)
		}
	}

	/// A pre-authenticated URL is a credential as a whole, so it is logged by its origin only.
	private static func urlLogging(of authorization: BearerRequestSender.Authorization) -> HTTPDebugLogger.URLLogging {
		switch authorization {
		case .bearer:
			return .redacted
		case .none:
			return .originOnly
		}
	}
}
