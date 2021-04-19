//
//  VaultConfig.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 01.03.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import JOSESwift

public enum VaultConfigError: Error {
	case signatureVerificationFailed
	case tokenSerializationFailed
}

public enum VaultCipherCombo: String, Codable {
	case sivCTRMAC = "SIV_CTRMAC"
	case sivGCM = "SIV_GCM"
}

struct VaultConfigPayload: Equatable, Codable {
	let jti: String
	let format: Int
	let cipherCombo: VaultCipherCombo
	let shorteningThreshold: Int

	static func fromJSONData(data: Data) throws -> VaultConfigPayload {
		let decoder = JSONDecoder()
		return try decoder.decode(VaultConfigPayload.self, from: data)
	}

	func toJSONData() throws -> Data {
		let encoder = JSONEncoder()
		return try encoder.encode(self)
	}
}

public class UnverifiedVaultConfig {
	private let token: String
	private let jws: JWS
	public var keyId: String? {
		return jws.header.kid
	}

	/**
	 Decodes a vault configuration stored in JWT format.

	 - Parameter token: The token in JWT format.
	 - Returns: New unverified vault configuration instance.
	 */
	public init(token: String) throws {
		self.token = token
		self.jws = try JWS(compactSerialization: token)
	}

	/**
	 Verifies signature of vault configuration.

	 - Parameter rawKey: The key matching the ID in `keyId`.
	 - Returns: Verified vault configuration instance.
	 */
	public func verify(rawKey: [UInt8]) throws -> VaultConfig {
		guard let verifier = Verifier(verifyingAlgorithm: .HS256, publicKey: Data(rawKey)) else {
			throw VaultConfigError.signatureVerificationFailed
		}
		let verifiedJWS = try jws.validate(using: verifier)
		return try VaultConfig(jsonData: verifiedJWS.payload.data())
	}
}

public class VaultConfig {
	public let id: String
	public let format: Int
	public let cipherCombo: VaultCipherCombo
	public let shorteningThreshold: Int

	init(id: String, format: Int, cipherCombo: VaultCipherCombo, shorteningThreshold: Int) {
		self.id = id
		self.format = format
		self.cipherCombo = cipherCombo
		self.shorteningThreshold = shorteningThreshold
	}

	fileprivate convenience init(jsonData: Data) throws {
		let payload = try VaultConfigPayload.fromJSONData(data: jsonData)
		self.init(id: payload.jti, format: payload.format, cipherCombo: payload.cipherCombo, shorteningThreshold: payload.shorteningThreshold)
	}

	/**
	 Creates new configuration object for a new vault.

	 - Parameter format: Vault format number, formerly known as vault version.
	 - Parameter cipherCombo: Ciphers to use for name/content encryption.
	 - Parameter shorteningThreshold: Maximum ciphertext filename length before it gets shortened.
	 - Returns: New vault configuration instance with a random ID.
	 */
	public static func createNew(format: Int, cipherCombo: VaultCipherCombo, shorteningThreshold: Int) -> VaultConfig {
		return VaultConfig(id: UUID().uuidString, format: format, cipherCombo: cipherCombo, shorteningThreshold: shorteningThreshold)
	}

	/**
	 Convenience wrapper for decoding and verifying vault configuration.

	 - Parameter token: The token in JWT format.
	 - Parameter rawKey: The key matching the ID in the `token`'s `keyId`.
	 - Returns: Verified vault configuration instance.
	 */
	public static func load(token: String, rawKey: [UInt8]) throws -> VaultConfig {
		let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)
		return try unverifiedVaultConfig.verify(rawKey: rawKey)
	}

	/**
	 Serializes vault configuration to a token in JWT format.

	 - Parameter keyId: The key ID as URI string referencing the location of the key material.
	 - Parameter rawKey: The key matching the ID in `keyId`.
	 - Returns: Signed token in JWT format.
	 */
	public func toToken(keyId: String, rawKey: [UInt8]) throws -> String {
		let header = try JWSHeader(parameters: ["typ": "JWT", "alg": SignatureAlgorithm.HS256.rawValue, "kid": keyId])
		let payload = try VaultConfigPayload(jti: id, format: format, cipherCombo: cipherCombo, shorteningThreshold: shorteningThreshold).toJSONData()
		guard let signer = Signer(signingAlgorithm: .HS256, privateKey: Data(rawKey)) else {
			throw VaultConfigError.tokenSerializationFailed
		}
		let jws = try JWS(header: header, payload: Payload(payload), signer: signer)
		return jws.compactSerializedString
	}
}
