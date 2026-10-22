//
//  WebAuthenticationSession.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif
import AuthenticationServices
import os
import UIKit

/**
 Runs a web authentication session and returns its callback URL.

 The session holds its presentation context provider weakly, so the provider is kept alive here until the session completes.

 - Parameter logPrefix: The name of the authenticator that the log lines start with.
 - Parameter convertError: Converts the error that the session completed with, or `nil` if it didn't start or completed without an error.
 */
@MainActor
// swiftlint:disable:next function_parameter_count
func runWebAuthenticationSession(url: URL, callbackURLScheme: String, anchor: ASPresentationAnchor, prefersEphemeralWebBrowserSession: Bool, logPrefix: String, convertError: @escaping @Sendable (Error?) -> Error) async throws -> URL {
	let contextProvider = PresentationContextProvider(anchor: anchor)
	defer {
		withExtendedLifetime(contextProvider) {}
	}
	return try await withCheckedThrowingContinuation { continuation in
		let pendingContinuation = OSAllocatedUnfairLock<CheckedContinuation<URL, Error>?>(initialState: continuation)
		let resume: @Sendable (Result<URL, Error>) -> Void = { result in
			let continuation = pendingContinuation.withLock { continuation in
				defer { continuation = nil }
				return continuation
			}
			continuation?.resume(with: result)
		}
		let webSession = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme) { @Sendable callbackURL, error in
			if let callbackURL {
				resume(.success(callbackURL))
			} else {
				resume(.failure(convertError(error)))
			}
		}
		webSession.presentationContextProvider = contextProvider
		webSession.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
		if !webSession.start() {
			// A session that didn't start may never run its completion handler.
			CloudAccessDDLogDebug("\(logPrefix): The web authentication session didn't start.")
			resume(.failure(convertError(nil)))
		}
	}
}

private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
	private let anchor: ASPresentationAnchor

	init(anchor: ASPresentationAnchor) {
		self.anchor = anchor
	}

	func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
		return anchor
	}
}
