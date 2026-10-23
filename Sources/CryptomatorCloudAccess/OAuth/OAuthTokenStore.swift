//
//  OAuthTokenStore.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import Foundation
import os

/// The in-process state of the token stores, shared by every store of the same lock directory, provider and account. Tests create their own coordinators to stand for separate processes.
final class OAuthTokenCoordinator: Sendable {
	static let shared = OAuthTokenCoordinator()

	fileprivate struct UnsavedToken {
		let token: OAuthToken
		/// The stored token that `token` was rotated from.
		let source: OAuthToken
	}

	fileprivate struct Entry {
		/// The last known token, which this process uses for its requests.
		var token: OAuthToken?
		/// A rotated token that couldn't be saved yet.
		var unsaved: UnsavedToken?
		var refresh: Task<OAuthToken, Error>?
	}

	fileprivate let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())
}

/**
 Keeps the OAuth token of one account in the storage of an `OAuthPersistence` and refreshes it once at a time in this process and, while the process holds an execution assertion, across processes.

 A refresh token may be single-use, so two refreshes with the same refresh token would log the user out. Hence, the stores of an account join a running refresh in their process. They refresh only while holding a `CrossProcessFileLock` in the lock directory, after re-reading the stored token. A refresh that finds the stored token already replaced by another process returns that one instead.

 The lock is held only while the process holds an execution assertion, and the only request sent while holding it is the refresh. If the assertion expires, the lock is released right away, because iOS terminates a suspended process that holds a file lock. Another process may then refresh with the same refresh token while the request is still under way. A response that arrives after the expiry is saved only if storage still holds the token it was rotated from.

 Only a storage write that is running at the expiry delays the release until it returns, so that the write can't land after another process took the lock. If the write blocks then, iOS may terminate the process, and a rotated token that wasn't saved yet is lost.

 Log lines name the provider and the outcome only, never a token.
 */
final class OAuthTokenStore: Sendable {
	private enum RefreshOutcome {
		case token(OAuthToken)
		/// The refresh response arrived after the assertion expired and the lock was released, so it isn't saved yet.
		case lateResponse(OAuthToken, rotatedFrom: OAuthToken)
	}

	/// How long before its known expiry an access token is refreshed.
	private static let refreshMargin: TimeInterval = 5 * 60

	private let accountKey: OAuthAccountKey
	private let storage: any OAuthTokenStorage
	private let lockDirectory: URL
	private let legacyDecoder: @Sendable (Data) throws -> OAuthToken
	private let refresher: @Sendable (OAuthToken) async throws -> OAuthToken
	private let assertion: ProcessExecutionAssertion
	private let now: @Sendable () -> Date
	private let lockTimeout: Duration
	private let lockPollInterval: Duration
	private let lockEvents: CrossProcessFileLock.Events
	private let coordinator: OAuthTokenCoordinator
	private let key: String

	/**
	 - Parameter legacyDecoder: Decodes a stored token without a version, e.g., one that an SDK stored.
	 - Parameter refresher: Sends the refresh grant of the given token once and returns the new token.
	 - Parameter lockTimeout: Longer than the longest refresh request, so that a waiting process outlasts a healthy refresh in another one.
	 */
	init(provider: OAuthProvider, account: String, persistence: OAuthPersistence, legacyDecoder: @escaping @Sendable (Data) throws -> OAuthToken, refresher: @escaping @Sendable (OAuthToken) async throws -> OAuthToken, assertion: ProcessExecutionAssertion = ProcessExecutionAssertion(), now: @escaping @Sendable () -> Date = Date.init, lockTimeout: Duration = .seconds(30), lockPollInterval: Duration = .milliseconds(50), lockEvents: CrossProcessFileLock.Events = .init(), coordinator: OAuthTokenCoordinator = .shared) {
		self.accountKey = OAuthAccountKey(provider: provider, account: account)
		self.storage = persistence.storage
		self.lockDirectory = persistence.tokenLockDirectory
		self.legacyDecoder = legacyDecoder
		self.refresher = refresher
		self.assertion = assertion
		self.now = now
		self.lockTimeout = lockTimeout
		self.lockPollInterval = lockPollInterval
		self.lockEvents = lockEvents
		self.coordinator = coordinator
		self.key = "\(persistence.tokenLockDirectory.path)|\(provider.rawValue)|\(account)"
	}

	// MARK: - Tokens

	/**
	 Returns the access token to send, after refreshing it if it is known to expire within `refreshMargin`. If that refresh fails before the token expired, the token is returned anyway.

	 - Throws: `CloudProviderError.unauthorized` if no token is stored, and the refresh error if the token has expired.
	 */
	func accessToken() async throws -> String {
		let token = try currentToken()
		guard let expiresAt = token.expiresAt, isDue(token) else {
			return token.accessToken
		}
		do {
			return try await refresh(rejecting: token.accessToken)
		} catch {
			guard expiresAt > now() else {
				throw error
			}
			CloudAccessDDLogDebug("OAuthTokenStore: \(accountKey.provider.rawValue) refresh before the expiry failed with \(error)")
			return token.accessToken
		}
	}

	/**
	 Returns a token that replaces the rejected access token, refreshing it unless another store or process did already.

	 The caller's cancellation doesn't cancel the refresh, which other callers may wait for.

	 - Throws: `CloudProviderError.unauthorized` if no token is stored or it can't be refreshed, `OAuthTokenStoreError.lockTimeout` or `.executionTimeUnavailable` if it couldn't be refreshed safely now, and otherwise what the refresher throws.
	 */
	func refresh(rejecting accessToken: String) async throws -> String {
		let refresh = withEntry { entry in
			if let refresh = entry.refresh {
				return refresh
			}
			let refresh = Task {
				try await self.performRefresh(rejecting: accessToken)
			}
			entry.refresh = refresh
			return refresh
		}
		return try await refresh.value.accessToken
	}

	/// Stores the token of a new login, replacing any stored token.
	func replace(with token: OAuthToken) async throws {
		try await underLock { slot in
			try self.save(token, holding: slot)
			self.publish(token)
		}
	}

	func storedUsername() throws -> String? {
		return try loadStoredToken()?.username
	}

	/**
	 Returns the stored token, read from storage on every call rather than from this process's state.

	 - Throws: `CloudProviderError.unauthorized` if no token is stored.
	 */
	func storedToken() throws -> OAuthToken {
		guard let token = try loadStoredToken() else {
			throw CloudProviderError.unauthorized
		}
		return token
	}

	/**
	 Stores the username with the stored login.

	 The token that this process uses stays as it is, including a rotated token that wasn't saved yet. The next refresh saves that one with the username, because the stored tokens are still those it was rotated from.

	 - Throws: `CloudProviderError.unauthorized` if no login is stored, and `OAuthTokenStoreError` if it couldn't be updated safely now.
	 */
	func updateUsername(_ username: String) async throws {
		try await underLock { slot in
			guard let storedToken = try self.loadStoredToken() else {
				throw CloudProviderError.unauthorized
			}
			guard storedToken.username != username else {
				return
			}
			try self.save(storedToken.replacingUsername(with: username), holding: slot)
		}
	}

	/**
	 Deletes the stored token and then revokes it. The token is deleted also if the revocation fails.

	 - Parameter revoke: Revokes the token. It runs after the lock is released, because the refresh is the only request sent while holding it.
	 - Throws: `OAuthTokenStoreError` if the token couldn't be updated safely now, a storage error, or what `revoke` throws. An undecodable item is deleted without a revocation.
	 */
	func delete(revoking revoke: @escaping @Sendable (OAuthToken) async throws -> Void) async throws {
		let token: OAuthToken? = try await underLock { slot in
			guard let data = try self.storage.load(self.accountKey) else {
				self.clearEntry()
				return nil
			}
			var token = try? OAuthTokenEncoding.decode(data, legacyDecoder: self.legacyDecoder)
			if let storedToken = token, let unsaved = self.withEntry({ $0.unsaved }), storedToken.hasSameTokens(as: unsaved.source) {
				// The unsaved token replaced the stored one, so it is the one to revoke.
				token = unsaved.token
			}
			try self.deleteStoredToken(holding: slot)
			self.clearEntry()
			return token
		}
		if let token {
			try await revoke(token)
		}
	}

	// MARK: - Refresh

	private func performRefresh(rejecting rejectedAccessToken: String) async throws -> OAuthToken {
		defer {
			withEntry { $0.refresh = nil }
		}
		let outcome: RefreshOutcome
		do {
			outcome = try await underLock { slot in
				try await self.refreshLocked(rejecting: rejectedAccessToken, slot: slot)
			}
		} catch OAuthTokenStoreError.lockTimeout {
			return try tokenAfterLockTimeout(rejecting: rejectedAccessToken)
		} catch {
			CloudAccessDDLogDebug("OAuthTokenStore: \(accountKey.provider.rawValue) refresh failed with \(error)")
			throw error
		}
		switch outcome {
		case let .token(token):
			return token
		case let .lateResponse(token, source):
			return try await saveLateResponse(token, rotatedFrom: source)
		}
	}

	private func refreshLocked(rejecting rejectedAccessToken: String, slot: LockHolderSlot) async throws -> RefreshOutcome {
		var storedToken = try loadStoredToken()
		if let unsaved = withEntry({ $0.unsaved }) {
			if let token = storedToken, token.hasSameTokens(as: unsaved.source) {
				let unsavedToken = unsaved.token.keepingUsername(of: token)
				try save(unsavedToken, holding: slot)
				storedToken = unsavedToken
			}
			// Otherwise, the unsaved token was saved already, or the stored token was replaced or deleted since.
			withEntry { $0.unsaved = nil }
		}
		guard let storedToken else {
			clearEntry()
			throw CloudProviderError.unauthorized
		}
		if storedToken.accessToken != rejectedAccessToken, !isDue(storedToken) {
			CloudAccessDDLogDebug("OAuthTokenStore: \(accountKey.provider.rawValue) token was refreshed elsewhere")
			publish(storedToken)
			return .token(storedToken)
		}
		guard storedToken.refreshToken != nil else {
			throw CloudProviderError.unauthorized
		}
		guard slot.isHeld else {
			throw OAuthTokenStoreError.executionTimeUnavailable
		}
		// No retry, because a refresh token may already be used up after a failed request.
		let refreshedToken = try await refresher(storedToken).keepingUsername(of: storedToken)
		guard slot.isHeld else {
			return .lateResponse(refreshedToken, rotatedFrom: storedToken)
		}
		saveRotatedToken(refreshedToken, rotatedFrom: storedToken, slot: slot)
		CloudAccessDDLogDebug("OAuthTokenStore: \(accountKey.provider.rawValue) token was refreshed")
		return .token(refreshedToken)
	}

	/// Saves a response that arrived after the lock was released, but only if no other process replaced or deleted the token it was rotated from meanwhile. If it can't be saved now, it is kept unsaved.
	private func saveLateResponse(_ refreshedToken: OAuthToken, rotatedFrom source: OAuthToken) async throws -> OAuthToken {
		do {
			return try await underLock { slot in
				guard let storedToken = try self.loadStoredToken() else {
					self.clearEntry()
					throw CloudProviderError.unauthorized
				}
				guard storedToken.hasSameTokens(as: source) else {
					self.publish(storedToken)
					return storedToken
				}
				// The username may have been stored meanwhile.
				let token = refreshedToken.keepingUsername(of: storedToken)
				self.saveRotatedToken(token, rotatedFrom: source, slot: slot)
				return token
			}
		} catch CloudProviderError.unauthorized {
			throw CloudProviderError.unauthorized
		} catch {
			CloudAccessDDLogDebug("OAuthTokenStore: \(accountKey.provider.rawValue) saving the late refresh response failed with \(error)")
			keepUnsaved(refreshedToken, rotatedFrom: source)
			return refreshedToken
		}
	}

	/// After waiting for the lock in vain, a stored token that differs from the rejected one is still usable, because the process that holds the lock has refreshed it already.
	private func tokenAfterLockTimeout(rejecting rejectedAccessToken: String) throws -> OAuthToken {
		guard withEntry({ $0.unsaved == nil }), let storedToken = try loadStoredToken(), storedToken.accessToken != rejectedAccessToken else {
			throw OAuthTokenStoreError.lockTimeout
		}
		publish(storedToken)
		return storedToken
	}

	/// Saves a rotated token. If saving fails, the token is kept in this process, so that the next refresh saves it instead of sending a used-up refresh token.
	private func saveRotatedToken(_ token: OAuthToken, rotatedFrom source: OAuthToken, slot: LockHolderSlot) {
		do {
			try save(token, holding: slot)
			publish(token)
		} catch {
			CloudAccessDDLogDebug("OAuthTokenStore: \(accountKey.provider.rawValue) saving the refreshed token failed with \(error)")
			keepUnsaved(token, rotatedFrom: source)
		}
	}

	// MARK: - Lock

	/// Runs the body while holding the lock and an execution assertion, whose expiry releases the lock.
	private func underLock<T: Sendable>(_ body: @escaping @Sendable (_ slot: LockHolderSlot) async throws -> T) async throws -> T {
		let slot = LockHolderSlot()
		return try await assertion.perform(reason: "Updating the \(accountKey.provider.rawValue) login", operation: {
			let holder = try await self.makeLock().acquire(timeout: self.lockTimeout, pollInterval: self.lockPollInterval)
			guard slot.install(holder) else {
				holder.release()
				throw OAuthTokenStoreError.executionTimeUnavailable
			}
			defer {
				slot.release()
			}
			return try await body(slot)
		}, onExpiration: {
			slot.release()
		})
	}

	func makeLock() -> CrossProcessFileLock {
		let accountHash = SHA256.hash(data: Data(accountKey.account.utf8)).map { String(format: "%02x", $0) }.joined()
		return CrossProcessFileLock(directory: lockDirectory, name: "\(accountKey.provider.rawValue)-\(accountHash)", events: lockEvents)
	}

	// MARK: - Storage

	private func currentToken() throws -> OAuthToken {
		if let token = withEntry({ $0.token }) {
			return token
		}
		guard let storedToken = try loadStoredToken() else {
			throw CloudProviderError.unauthorized
		}
		return withEntry { entry in
			if let token = entry.token {
				return token
			}
			entry.token = storedToken
			return storedToken
		}
	}

	private func loadStoredToken() throws -> OAuthToken? {
		guard let data = try storage.load(accountKey) else {
			return nil
		}
		return try OAuthTokenEncoding.decode(data, legacyDecoder: legacyDecoder)
	}

	private func save(_ token: OAuthToken, holding slot: LockHolderSlot) throws {
		let data = try OAuthTokenEncoding.encode(token)
		try slot.write {
			try storage.save(data, for: accountKey)
		}
	}

	private func deleteStoredToken(holding slot: LockHolderSlot) throws {
		try slot.write {
			try storage.delete(accountKey)
		}
	}

	private func isDue(_ token: OAuthToken) -> Bool {
		return token.expiresAt.map { $0.timeIntervalSince(now()) < OAuthTokenStore.refreshMargin } ?? false
	}

	// MARK: - Coordinator

	private func withEntry<T: Sendable>(_ body: @Sendable (inout OAuthTokenCoordinator.Entry) -> T) -> T {
		return coordinator.entries.withLock { entries in
			body(&entries[key, default: OAuthTokenCoordinator.Entry()])
		}
	}

	private func publish(_ token: OAuthToken) {
		withEntry { entry in
			entry.token = token
			entry.unsaved = nil
		}
	}

	private func keepUnsaved(_ token: OAuthToken, rotatedFrom source: OAuthToken) {
		withEntry { entry in
			entry.token = token
			entry.unsaved = OAuthTokenCoordinator.UnsavedToken(token: token, source: source)
		}
	}

	private func clearEntry() {
		withEntry { entry in
			entry.token = nil
			entry.unsaved = nil
		}
	}
}

/// The lock holder of one assertion. The expiry of the assertion releases it right away, or once a running `write(_:)` returns. A holder installed after the expiry is refused.
private final class LockHolderSlot: Sendable {
	private enum State {
		case empty
		case held(CrossProcessFileLock.Holder)
		case released
	}

	private let state = OSAllocatedUnfairLock(initialState: State.empty)

	var isHeld: Bool {
		return state.withLock { state in
			guard case .held = state else {
				return false
			}
			return true
		}
	}

	func install(_ holder: CrossProcessFileLock.Holder) -> Bool {
		return state.withLock { state in
			guard case .empty = state else {
				return false
			}
			state = .held(holder)
			return true
		}
	}

	/**
	 Runs a storage write if the lock is still held. The expiry waits for it, so that a write that iOS suspends with the process can't land after another process took the lock.

	 - Throws: `OAuthTokenStoreError.executionTimeUnavailable` without running the write if the lock was released.
	 */
	func write(_ body: () throws -> Void) throws {
		try state.withLockUnchecked { state in
			guard case .held = state else {
				throw OAuthTokenStoreError.executionTimeUnavailable
			}
			try body()
		}
	}

	/// Releases the lock. A holder installed afterwards is refused.
	func release() {
		let holder: CrossProcessFileLock.Holder? = state.withLock { state in
			defer {
				state = .released
			}
			guard case let .held(holder) = state else {
				return nil
			}
			return holder
		}
		holder?.release()
	}
}
