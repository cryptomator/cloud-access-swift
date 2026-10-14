//
//  DropboxAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif
import Foundation
@preconcurrency import ObjectiveDropboxOfficial
import os

public enum DropboxAuthenticatorError: Error {
	case authenticationFailed
}

@MainActor
public final class DropboxAuthenticator {
	private nonisolated static let pendingAuthentication = OSAllocatedUnfairLock<(id: UUID, continuation: CheckedContinuation<DropboxCredential, any Error>)?>(initialState: nil)
	private static let scopes = ["files.metadata.read", "files.metadata.write", "files.content.read", "files.content.write", "account_info.read"]
	private static let scopeRequest = DBScopeRequest(scopeType: DBScopeType.user, scopes: scopes, includeGrantedScopes: false)
	public init() {
		DropboxClientSetup.oneTimeSetup()
	}

	/**
	 Starts the authentication flow and waits until the app passes its redirect URL to `handleRedirectURL(_:)`.

	 Only one authentication can be pending at a time, so a new call fails the previous one with `DropboxAuthenticatorError.authenticationFailed`. Because the redirect may never arrive, cancelling the task ends the call with `CancellationError`.
	 */
	@available(iOSApplicationExtension, unavailable)
	public func authenticate(from viewController: UIViewController) async throws -> DropboxCredential {
		let id = UUID()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				let supersededAuthentication = DropboxAuthenticator.pendingAuthentication.withLock { pendingAuthentication in
					defer { pendingAuthentication = (id, continuation) }
					return pendingAuthentication?.continuation
				}
				supersededAuthentication?.resume(throwing: DropboxAuthenticatorError.authenticationFailed)
				// The cancellation handler finds nothing to resume if it ran before the authentication was stored.
				guard !Task.isCancelled else {
					DropboxAuthenticator.takePendingAuthentication(withID: id)?.resume(throwing: CancellationError())
					return
				}
				DBClientsManager.authorize(fromControllerV2: .shared, controller: viewController, loadingStatusDelegate: nil, openURL: { url in
					UIApplication.shared.open(url, options: [:], completionHandler: nil)
				}, scopeRequest: DropboxAuthenticator.scopeRequest)
			}
		} onCancel: {
			DropboxAuthenticator.takePendingAuthentication(withID: id)?.resume(throwing: CancellationError())
		}
	}

	/**
	 Completes the pending authentication with the redirect URL that the app received once the authentication flow is finished.

	 - Returns: Whether the redirect URL was handled by the Dropbox SDK.
	 */
	public static func handleRedirectURL(_ url: URL) -> Bool {
		return DBClientsManager.handleRedirectURL(url) { @Sendable authResult in
			guard let authResult else {
				return
			}
			if authResult.isSuccess() {
				takePendingAuthentication()?.resume(returning: DropboxCredential(tokenUID: authResult.accessToken.uid))
			} else if authResult.isCancel() {
				takePendingAuthentication()?.resume(throwing: CocoaError(.userCancelled))
			} else if authResult.isError() {
				takePendingAuthentication()?.resume(throwing: authResult.nsError)
			}
		}
	}

	/// Hands out the pending authentication at most once, so that only one of redirect, cancellation and a newer authentication resumes it.
	private nonisolated static func takePendingAuthentication(withID id: UUID? = nil) -> CheckedContinuation<DropboxCredential, any Error>? {
		return pendingAuthentication.withLock { pendingAuthentication in
			guard let authentication = pendingAuthentication, id == nil || id == authentication.id else {
				return nil
			}
			pendingAuthentication = nil
			return authentication.continuation
		}
	}
}
