//
//  OAuthTokenSourceStub.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// Hands out `TOKEN` until a refresh rejects it, and `REFRESHED` afterwards. Keeps the username in memory.
final class OAuthTokenSourceStub: OAuthTokenSource {
	private struct State {
		var token = "TOKEN"
		var rejectedTokens = [String]()
		var username: String?
		var failsUsernameUpdates = false
		var deauthenticationCount = 0
	}

	private let state = OSAllocatedUnfairLock(initialState: State())
	private let onAccessToken: @Sendable () async -> Void
	private let onRefresh: @Sendable () async -> Void

	init(username: String? = nil, onAccessToken: @escaping @Sendable () async -> Void = {}, onRefresh: @escaping @Sendable () async -> Void = {}) {
		self.onAccessToken = onAccessToken
		self.onRefresh = onRefresh
		state.withLock { $0.username = username }
	}

	var rejectedTokens: [String] {
		return state.withLock { $0.rejectedTokens }
	}

	var deauthenticationCount: Int {
		return state.withLock { $0.deauthenticationCount }
	}

	var failsUsernameUpdates: Bool {
		get { state.withLock { $0.failsUsernameUpdates } }
		set { state.withLock { $0.failsUsernameUpdates = newValue } }
	}

	func accessToken() async throws -> String {
		await onAccessToken()
		return state.withLock { $0.token }
	}

	func refresh(rejecting accessToken: String) async throws -> String {
		state.withLock { $0.rejectedTokens.append(accessToken) }
		await onRefresh()
		return state.withLock { state in
			state.token = "REFRESHED"
			return state.token
		}
	}

	func storedUsername() throws -> String? {
		return state.withLock { $0.username }
	}

	func updateUsername(_ username: String) async throws {
		try state.withLock { state in
			guard !state.failsUsernameUpdates else {
				throw CocoaError(.fileWriteUnknown)
			}
			state.username = username
		}
	}

	func deauthenticate() async throws {
		state.withLock { $0.deauthenticationCount += 1 }
	}
}
