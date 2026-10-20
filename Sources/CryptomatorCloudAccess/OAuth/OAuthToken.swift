//
//  OAuthToken.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum OAuthTokenStoreError: Error, Equatable {
	/// Another holder kept the token lock for too long. Nothing was changed, so the call can be retried later.
	case lockTimeout
	/// The process got no background execution time to update the token safely. Nothing was changed, so the call can be retried later.
	case executionTimeUnavailable
	/// The stored token was written by a newer version of the library. Requests fail without changing it, and only a new login or a deletion replaces it.
	case unsupportedVersion(Int)
	/// The token lock directory isn't a file URL.
	case invalidLockDirectory
}

struct OAuthToken: Sendable, Equatable {
	let accessToken: String
	let refreshToken: String?
	/// When the access token expires, or `nil` if that is unknown, e.g., for a token stored by an SDK.
	let expiresAt: Date?

	/// Whether both tokens are the same grant, regardless of the precision of the stored expiry.
	func hasSameTokens(as other: OAuthToken) -> Bool {
		return accessToken == other.accessToken && refreshToken == other.refreshToken
	}
}

/// The versioned JSON format in which the library stores tokens.
enum OAuthTokenEncoding {
	private static let currentVersion = 1

	private struct VersionedEnvelope: Decodable {
		let version: Int?
	}

	private struct Envelope: Codable {
		let version: Int
		let accessToken: String
		let refreshToken: String?
		/// Seconds since 1970.
		let expiresAt: TimeInterval?
	}

	static func encode(_ token: OAuthToken) throws -> Data {
		return try JSONEncoder().encode(Envelope(version: currentVersion, accessToken: token.accessToken, refreshToken: token.refreshToken, expiresAt: token.expiresAt?.timeIntervalSince1970))
	}

	/**
	 Decodes a token that this library stored, or passes data without a version, e.g., a token stored by an SDK, to `legacyDecoder`.

	 - Throws: `OAuthTokenStoreError.unsupportedVersion` for a version other than 1, and otherwise a decoding error or what `legacyDecoder` throws.
	 */
	static func decode(_ data: Data, legacyDecoder: (Data) throws -> OAuthToken) throws -> OAuthToken {
		guard let version = (try? JSONDecoder().decode(VersionedEnvelope.self, from: data))?.version else {
			return try legacyDecoder(data)
		}
		guard version == currentVersion else {
			throw OAuthTokenStoreError.unsupportedVersion(version)
		}
		let envelope = try JSONDecoder().decode(Envelope.self, from: data)
		return OAuthToken(accessToken: envelope.accessToken, refreshToken: envelope.refreshToken, expiresAt: envelope.expiresAt.map(Date.init(timeIntervalSince1970:)))
	}
}
