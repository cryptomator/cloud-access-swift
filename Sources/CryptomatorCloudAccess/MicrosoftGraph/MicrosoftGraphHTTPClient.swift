//
//  MicrosoftGraphHTTPClient.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

protocol MicrosoftGraphAccessTokenProvider: Sendable {
	func getAccessToken() async throws -> String
}

/**
 Sends authorized requests to Microsoft Graph and retries those that are throttled or hit an unavailable service.

 Requests run on a `SplitURLSession`, which doesn't forward cancellation. Cancellation only cuts short the delay before a retry.
 */
final class MicrosoftGraphHTTPClient: Sendable {
	private static let retriedStatusCodes: Set<Int> = [429, 503, 504]
	private static let maxRetryCount = 3

	private let accessTokenProvider: MicrosoftGraphAccessTokenProvider
	private let session: SplitURLSession

	init(accessTokenProvider: MicrosoftGraphAccessTokenProvider, configuration: URLSessionConfiguration) {
		self.accessTokenProvider = accessTokenProvider
		self.session = SplitURLSession(configuration: configuration)
	}

	func data(for request: URLRequest, bodyLogging: HTTPDebugLogger.BodyLogging = .logged) async throws -> (HTTPURLResponse, Data) {
		return try await send(authorize(request)) { try await self.session.data(for: $0, bodyLogging: bodyLogging) }
	}

	/// Moves the body of a 2xx response to `destinationURL`, replacing any item there. The body of any other response is discarded.
	func download(_ request: URLRequest, to destinationURL: URL) async throws -> HTTPURLResponse {
		let (response, _) = try await send(authorize(request)) { try await self.session.download($0, to: destinationURL) }
		return response
	}

	/// Sends the request without an `Authorization` header, which an upload URL of an upload session must not receive. The upload URL is pre-authenticated, possibly by a token in its path, so only its origin is logged.
	func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (HTTPURLResponse, Data) {
		return try await send(request) { try await self.session.upload($0, fromFile: fileURL, urlLogging: .originOnly) }
	}

	private func authorize(_ request: URLRequest) async throws -> URLRequest {
		var request = request
		try await request.setValue("Bearer \(accessTokenProvider.getAccessToken())", forHTTPHeaderField: "Authorization")
		return request
	}

	private func send(_ request: URLRequest, with perform: (URLRequest) async throws -> (HTTPURLResponse, Data)) async throws -> (HTTPURLResponse, Data) {
		var retryCount = 0
		while true {
			let (response, data) = try await perform(request)
			guard MicrosoftGraphHTTPClient.retriedStatusCodes.contains(response.statusCode), retryCount < MicrosoftGraphHTTPClient.maxRetryCount else {
				return (response, data)
			}
			retryCount += 1
			try await Task.sleep(for: .seconds(retryDelay(for: response, retryCount: retryCount)))
		}
	}

	private func retryDelay(for response: HTTPURLResponse, retryCount: Int) -> Int {
		if let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) {
			return retryAfter
		}
		return 1 + 2 * retryCount
	}
}
