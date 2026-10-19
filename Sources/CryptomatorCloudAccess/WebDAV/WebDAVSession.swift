//
//  WebDAVSession.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 07.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum URLSessionError: Error {
	case httpError(_ error: Error?, statusCode: Int)
	case unexpectedResponse
}

/// Answers the per-task challenges of a WebDAV server, e.g., Basic or Digest, with the credential, and trusts the server certificate that the credential allows. The other session-level challenges, e.g., NTLM or a client certificate, get default handling.
struct WebDAVChallengeHandler: SplitURLSession.ChallengeHandler {
	private static let sessionWideAuthenticationMethods = [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate]

	let credential: WebDAVCredential

	func decision(for challenge: URLAuthenticationChallenge, task: URLSessionTask) -> SplitURLSession.ChallengeDecision {
		return WebDAVChallengeHandler.decision(authenticationMethod: challenge.protectionSpace.authenticationMethod, previousFailureCount: challenge.previousFailureCount, serverTrust: challenge.protectionSpace.serverTrust, credential: credential)
	}

	static func decision(authenticationMethod: String, previousFailureCount: Int, serverTrust: SecTrust?, credential: WebDAVCredential) -> SplitURLSession.ChallengeDecision {
		if sessionWideAuthenticationMethods.contains(authenticationMethod) {
			guard previousFailureCount < 1 else {
				return SplitURLSession.ChallengeDecision(disposition: .cancelAuthenticationChallenge, credential: nil, failure: nil)
			}
			if authenticationMethod == NSURLAuthenticationMethodServerTrust, let serverTrust, let allowedCertificate = credential.allowedCertificate, serverTrust.leafCertificateData == allowedCertificate {
				return SplitURLSession.ChallengeDecision(disposition: .useCredential, credential: URLCredential(trust: serverTrust), failure: nil)
			}
			return SplitURLSession.ChallengeDecision(disposition: .performDefaultHandling, credential: nil, failure: nil)
		} else {
			guard previousFailureCount < 1 else {
				return SplitURLSession.ChallengeDecision(disposition: .cancelAuthenticationChallenge, credential: nil, failure: URLSessionError.httpError(nil, statusCode: 401))
			}
			return SplitURLSession.ChallengeDecision(disposition: .useCredential, credential: URLCredential(user: credential.username, password: credential.password, persistence: .forSession), failure: nil)
		}
	}
}

/// Runs WebDAV requests on a `SplitURLSession` and maps their outcomes strictly: anything but a 2xx response throws.
final class WebDAVSession: Sendable {
	/// The maximum length of a response body that is kept in memory. A longer body fails the request with `URLSessionError.unexpectedResponse`. Only the debug log tells this cause apart from other unexpected responses.
	private static let maxResponseBodyLength = 1024 * 1024

	private let session: SplitURLSession

	init(credential: WebDAVCredential, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks(), registry: BackgroundURLSessionRegistry = .shared) {
		self.session = SplitURLSession(configuration: configuration, metadataConfiguration: metadataConfiguration, challengeHandler: WebDAVChallengeHandler(credential: credential), hooks: hooks, registry: registry)
	}

	/**
	 Creates a WebDAV session whose file downloads and uploads run on a background URL session, and whose other requests, including streamed folder listings, run on a foreground URL session.

	 If the `WebDAVSession` is used in an app extension, set the `sharedContainerIdentifier` to a valid identifier for a container that will be shared between the app and the extension.
	 */
	static func createBackgroundSession(credential: WebDAVCredential, sessionIdentifier: String, sharedContainerIdentifier: String? = nil) -> WebDAVSession {
		let configuration = hardened(.background(withIdentifier: sessionIdentifier))
		configuration.sharedContainerIdentifier = sharedContainerIdentifier
		return WebDAVSession(credential: credential, configuration: configuration, metadataConfiguration: hardened(.default))
	}

	convenience init(credential: WebDAVCredential) {
		self.init(credential: credential, configuration: WebDAVSession.hardened(.default), metadataConfiguration: nil)
	}

	private static func hardened(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
		configuration.httpCookieStorage = HTTPCookieStorage()
		configuration.urlCredentialStorage = nil
		return configuration
	}

	// MARK: - Requests

	func performDataTask(with request: URLRequest) async throws -> (HTTPURLResponse, Data?) {
		let outcome = try await session.data(request, bodyLimit: WebDAVSession.maxResponseBodyLength, bodyLogging: .logged)
		return try (WebDAVSession.successfulResponse(of: outcome), outcome.data)
	}

	func performDownloadTask(with request: URLRequest, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> HTTPURLResponse {
		let outcome = try await session.download(request, route: .transfer, handler: WebDAVSession.downloadHandler(movingTo: localURL), bodyLogging: .logged, progress: progress, cancelsBeforeResume: true, onTaskCreation: onTaskCreation)
		return try WebDAVSession.successfulDownloadResponse(of: outcome)
	}

	/// Streams the response of a metadata request, e.g., a folder listing, to `localURL` on the foreground session.
	func performMetadataDownloadTask(with request: URLRequest, to localURL: URL) async throws -> HTTPURLResponse {
		let outcome = try await session.download(request, route: .metadata, handler: WebDAVSession.downloadHandler(movingTo: localURL), bodyLogging: .logged, progress: nil, cancelsBeforeResume: true, onTaskCreation: nil)
		return try WebDAVSession.successfulDownloadResponse(of: outcome)
	}

	func performUploadTask(with request: URLRequest, fromFile fileURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> (HTTPURLResponse, Data?) {
		let outcome = try await session.upload(request, fromFile: fileURL, bodyLimit: WebDAVSession.maxResponseBodyLength, bodyLogging: .logged, urlLogging: .redacted, progress: progress, cancelsBeforeResume: true, onTaskCreation: onTaskCreation)
		return try (WebDAVSession.successfulResponse(of: outcome), outcome.data)
	}

	// MARK: - Outcomes

	/// Moves the body of a 2xx download to `localURL`, failing if an item exists there. The body of any other response is left to the system, which deletes it.
	static func downloadHandler(movingTo localURL: URL) -> SplitURLSession.DownloadHandler {
		return { location, response in
			guard let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) else {
				return .none
			}
			try FileManager.default.moveItem(at: location, to: localURL)
			return .file(localURL)
		}
	}

	static func successfulResponse(of outcome: SplitURLSession.Outcome) throws -> HTTPURLResponse {
		if case let SplitURLSessionError.responseBodyTooLarge(limit)? = outcome.recordedFailure {
			CloudAccessDDLogDebug("WebDAVSession: discarded a response body over \(limit) bytes from \(HTTPDebugLogger.redactedURLString(outcome.response?.url))")
			throw URLSessionError.unexpectedResponse
		} else if let recordedFailure = outcome.recordedFailure {
			throw recordedFailure
		}
		switch (outcome.response, outcome.error) {
		case let (_, .some(error)) where isCancellationError(error):
			throw CancellationError()
		case let (httpResponse as HTTPURLResponse, .some(error)):
			throw URLSessionError.httpError(error, statusCode: httpResponse.statusCode)
		case let (_, .some(error)):
			throw error
		case let (httpResponse as HTTPURLResponse, nil):
			guard (200 ... 299).contains(httpResponse.statusCode) else {
				throw URLSessionError.httpError(nil, statusCode: httpResponse.statusCode)
			}
			return httpResponse
		default:
			throw URLSessionError.unexpectedResponse
		}
	}

	static func successfulDownloadResponse(of outcome: SplitURLSession.Outcome) throws -> HTTPURLResponse {
		let httpResponse = try successfulResponse(of: outcome)
		guard case .file = outcome.body else {
			throw URLSessionError.unexpectedResponse
		}
		return httpResponse
	}
}
