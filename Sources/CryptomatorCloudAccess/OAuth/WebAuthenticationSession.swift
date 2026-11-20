//
//  WebAuthenticationSession.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
import CryptomatorCloudAccessCore
import os
import UIKit

/// A login in a browser or an SDK's sheet that `runWebAuthenticationSession(logPrefix:convertError:makeSession:)` starts, and cancels when the calling task is cancelled.
@MainActor
protocol WebLoginSession: AnyObject {
	/// - Returns: Whether the session started.
	func start() -> Bool
	func cancel()
}

extension ASWebAuthenticationSession: WebLoginSession {}

/// A login that an SDK runs, e.g., AppAuth or MSAL.
@MainActor
final class SDKLoginSession: WebLoginSession {
	private let begin: @MainActor () -> @MainActor () -> Void
	private var end: (@MainActor () -> Void)?

	/// - Parameter begin: Begins the login and returns the function that cancels it.
	init(begin: @escaping @MainActor () -> @MainActor () -> Void) {
		self.begin = begin
	}

	func start() -> Bool {
		end = begin()
		return true
	}

	func cancel() {
		end?()
	}
}

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
	return try await runWebAuthenticationSession(logPrefix: logPrefix, convertError: convertError) { (completion: @escaping @Sendable (URL?, Error?) -> Void) in
		let session = if #available(iOS 17.4, *) {
			ASWebAuthenticationSession(url: url, callback: .customScheme(callbackURLScheme), completionHandler: completion)
		} else {
			ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme, completionHandler: completion)
		}
		session.presentationContextProvider = contextProvider
		session.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
		return session
	}
}

/**
 Starts the session that `makeSession` creates, and waits until it completes or the task is cancelled. Cancelling the task cancels the session, which dismisses its page, and ends the call with `CancellationError`.

 - Parameter convertError: Converts the error that the session completed with without a result, or `nil` if it didn't start or completed without either.
 - Parameter makeSession: Creates the session with its completion handler, which gets the session's result or else its error. Of the session's completion, a failed start and the task's cancellation, only the first ends this call.
 */
@MainActor
func runWebAuthenticationSession<Output: Sendable>(logPrefix: String, convertError: @escaping @Sendable (Error?) -> Error, makeSession: (_ completion: @escaping @Sendable (Output?, Error?) -> Void) -> any WebLoginSession) async throws -> Output {
	let pendingContinuation = OSAllocatedUnfairLock<CheckedContinuation<Output, Error>?>(initialState: nil)
	let takeContinuation: @Sendable () -> CheckedContinuation<Output, Error>? = {
		pendingContinuation.withLock { continuation in
			defer { continuation = nil }
			return continuation
		}
	}
	let session = makeSession { output, error in
		guard let continuation = takeContinuation() else {
			return
		}
		if let output {
			continuation.resume(returning: output)
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

/// The checks of a web login's callback URL and of the error that its session ended with, which log with the authenticator's prefix.
struct WebLoginCallback: Sendable {
	/// The name of the authenticator that the log lines start with.
	let logPrefix: String
	/// The error that a failed login throws, unless the user cancelled it.
	let failure: any Error

	func userCancelled() -> CocoaError {
		CloudAccessDDLogDebug("\(logPrefix): Login flow canceled by the user.")
		return CocoaError(.userCancelled)
	}

	func authenticationFailed(because reason: String) -> any Error {
		CloudAccessDDLogDebug("\(logPrefix): Authentication failed, because \(reason).")
		return failure
	}

	/**
	 Converts an error of the web authentication session: a cancelled login to `CocoaError(.userCancelled)`, and any other session error to the failure.

	 - Returns: `nil` for an error that isn't the session's.
	 */
	func convertSessionError(_ error: Error) -> Error? {
		guard let sessionError = error as? ASWebAuthenticationSessionError else {
			return nil
		}
		if sessionError.code == .canceledLogin {
			return userCancelled()
		}
		CloudAccessDDLogDebug("\(logPrefix): Authentication failed with error: \(sessionError.localizedDescription).")
		return failure
	}

	/**
	 Returns the components of the callback URL if its scheme and, if given, its host match the redirect URI's, compared case-insensitively.

	 - Throws: The failure if they don't match.
	 */
	func components(ofCallbackURL callbackURL: URL, scheme: String, host: String?) throws -> URLComponents {
		guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false), components.scheme?.lowercased() == scheme.lowercased(), host.map({ components.host?.lowercased() == $0.lowercased() }) ?? true else {
			throw authenticationFailed(because: "the callback URL doesn't match the redirect URI")
		}
		return components
	}

	/// Throws `CocoaError(.userCancelled)` for an `error` of `access_denied`, which means that the user denied access, and the failure for any other `error`.
	func checkError(_ value: String?, providerName: String) throws {
		if value == "access_denied" {
			throw userCancelled()
		}
		guard value == nil else {
			throw authenticationFailed(because: "\(providerName) returned an error")
		}
	}

	/// Throws the failure if the callback's `state` isn't the request's.
	func checkState(_ value: String?, expected: String) throws {
		guard value == expected else {
			throw authenticationFailed(because: "the state doesn't match")
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
