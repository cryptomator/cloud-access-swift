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

/// A login in a browser that `runWebAuthenticationSession(logPrefix:convertError:makeSession:)` starts, and cancels when the calling task is cancelled.
@MainActor
protocol WebLoginSession: AnyObject {
	/// - Returns: Whether the session started.
	func start() -> Bool
	func cancel()
}

extension ASWebAuthenticationSession: WebLoginSession {}

/**
 Runs a web authentication session and returns its callback URL.

 Cancelling the task cancels the session, which dismisses its page, and ends the call with `CancellationError`.

 - Parameter logPrefix: The name of the authenticator that the log lines start with.
 - Parameter convertError: Converts the error that the session completed with, or `nil` if it didn't start or completed without an error.
 */
@MainActor
// swiftlint:disable:next function_parameter_count
func runWebAuthenticationSession(url: URL, callbackURLScheme: String, anchor: ASPresentationAnchor, prefersEphemeralWebBrowserSession: Bool, logPrefix: String, convertError: @escaping @Sendable (Error?) -> Error) async throws -> URL {
	let contextProvider = PresentationContextProvider(anchor: anchor)
	// The session holds its presentation context provider weakly.
	defer {
		withExtendedLifetime(contextProvider) {}
	}
	return try await runWebAuthenticationSession(logPrefix: logPrefix, convertError: convertError) { completion in
		let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme, completionHandler: completion)
		session.presentationContextProvider = contextProvider
		session.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
		return session
	}
}

/**
 Starts the session that `makeSession` creates, and waits until it completes or the task is cancelled.

 - Parameter makeSession: Creates the session with its completion handler. Of the session's completion, a failed start and the task's cancellation, only the first ends this call.
 */
@MainActor
func runWebAuthenticationSession(logPrefix: String, convertError: @escaping @Sendable (Error?) -> Error, makeSession: (_ completion: @escaping @Sendable (URL?, Error?) -> Void) -> any WebLoginSession) async throws -> URL {
	let pendingContinuation = OSAllocatedUnfairLock<CheckedContinuation<URL, Error>?>(initialState: nil)
	let takeContinuation: @Sendable () -> CheckedContinuation<URL, Error>? = {
		pendingContinuation.withLock { continuation in
			defer { continuation = nil }
			return continuation
		}
	}
	let session = makeSession { callbackURL, error in
		guard let continuation = takeContinuation() else {
			return
		}
		if let callbackURL {
			continuation.resume(returning: callbackURL)
		} else {
			continuation.resume(throwing: convertError(error))
		}
	}
	let cancelSession: @MainActor @Sendable () -> Void = {
		session.cancel()
	}
	return try await withTaskCancellationHandler {
		try await withCheckedThrowingContinuation { continuation in
			pendingContinuation.withLock { $0 = continuation }
			// The cancellation handler finds nothing to resume if it ran before the continuation was stored.
			guard !Task.isCancelled else {
				takeContinuation()?.resume(throwing: CancellationError())
				return
			}
			guard session.start() else {
				// A session that didn't start may never run its completion handler.
				CloudAccessDDLogDebug("\(logPrefix): The web authentication session didn't start.")
				takeContinuation()?.resume(throwing: convertError(nil))
				return
			}
		}
	} onCancel: {
		guard let continuation = takeContinuation() else {
			return
		}
		continuation.resume(throwing: CancellationError())
		Task {
			await cancelSession()
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
