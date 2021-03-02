//
//  VaultConfig.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 01.03.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import SwiftJWT

public enum VaultConfigError: Error {
	case signatureVerificationFailed
}

public enum VaultCipherCombo: String, Codable {
	case sivCTRMAC = "SIV_CTRMAC"
	case sivGCM = "SIV_GCM"
}

private struct VaultConfigClaims: Claims {
	let jti: String
	let format: Int
	let cipherCombo: VaultCipherCombo
	let maxFilenameLen: Int
}

public class UnverifiedVaultConfig {
	private let token: String
	private let jwt: JWT<VaultConfigClaims>
	public var keyId: String? {
		return jwt.header.kid
	}

	/**
	 Decodes a vault configuration stored in JWT format.

	 - Parameter token: The token in JWT format.
	 - Returns: New unverified vault configuration instance.
	 */
	public init(token: String) throws {
		self.token = token
		self.jwt = try JWT<VaultConfigClaims>(jwtString: token)
	}

	/**
	 Verifies signature of vault configuration.

	 - Parameter rawKey: The key matching the ID in `keyId`.
	 - Returns: Verified vault configuration instance.
	 */
	public func verify(rawKey: [UInt8]) throws -> VaultConfig {
		let verifier = JWTVerifier.hs256(key: Data(rawKey))
		let verified = JWT<VaultConfigClaims>.verify(token, using: verifier)
		if verified {
			return VaultConfig(claims: jwt.claims)
		} else {
			throw VaultConfigError.signatureVerificationFailed
		}
	}
}

public class VaultConfig {
	public let id: String
	public let format: Int
	public let cipherCombo: VaultCipherCombo
	public let maxFilenameLength: Int

	private var claims: VaultConfigClaims {
		return VaultConfigClaims(jti: id, format: format, cipherCombo: cipherCombo, maxFilenameLen: maxFilenameLength)
	}

	private init(id: String, format: Int, cipherCombo: VaultCipherCombo, maxFilenameLength: Int) {
		self.id = id
		self.format = format
		self.cipherCombo = cipherCombo
		self.maxFilenameLength = maxFilenameLength
	}

	fileprivate convenience init(claims: VaultConfigClaims) {
		self.init(id: claims.jti, format: claims.format, cipherCombo: claims.cipherCombo, maxFilenameLength: claims.maxFilenameLen)
	}

	/**
	 Creates new configuration object for a new vault.

	 - Parameter format: Vault format number, formerly known as vault version.
	 - Parameter cipherCombo: Ciphers to use for name/content encryption.
	 - Parameter maxFilenameLength: Maximum ciphertext filename length.
	 - Returns: New vault configuration instance with a random ID.
	 */
	public static func createNew(format: Int, cipherCombo: VaultCipherCombo, maxFilenameLength: Int) -> VaultConfig {
		return VaultConfig(id: UUID().uuidString, format: format, cipherCombo: cipherCombo, maxFilenameLength: maxFilenameLength)
	}

	/**
	 Serializes vault configuration to a token in JWT format.

	 - Parameter keyId: The key ID as URI string referencing the location of the key material.
	 - Parameter rawKey: The key matching the ID in `keyId`.
	 - Returns: Signed token in JWT format.
	 */
	public func toToken(keyId: String, rawKey: [UInt8]) throws -> String {
		let signer = JWTSigner.hs256(key: Data(rawKey))
		let header = Header(kid: keyId)
		var jwt = JWT(header: header, claims: claims)
		return try jwt.sign(using: signer)
	}
}
