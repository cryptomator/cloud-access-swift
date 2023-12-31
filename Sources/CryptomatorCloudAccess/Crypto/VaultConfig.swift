//
//  VaultConfig.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 01.03.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import JOSESwift

public enum VaultConfigError: Error {
	case unsupportedAlgorithm
	case signatureVerificationFailed
	case tokenSerializationFailed
}

struct VaultConfigPayload: Equatable, Codable {
	let jti: String
	let format: Int
	let cipherCombo: String
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

public struct HubConfig: Equatable, Codable {
	public let clientId: String
	public let authEndpoint: String
	public let tokenEndpoint: String
	public let authSuccessUrl: String
	public let authErrorUrl: String
	public let apiBaseUrl: String?
	public let devicesResourceUrl: String

	public init(clientId: String, authEndpoint: String, tokenEndpoint: String, authSuccessUrl: String, authErrorUrl: String, apiBaseUrl: String?, devicesResourceUrl: String) {
		self.clientId = clientId
		self.authEndpoint = authEndpoint
		self.tokenEndpoint = tokenEndpoint
		self.authSuccessUrl = authSuccessUrl
		self.authErrorUrl = authErrorUrl
		self.apiBaseUrl = apiBaseUrl
		self.devicesResourceUrl = devicesResourceUrl
	}
}

public class UnverifiedVaultConfig {
	public var keyId: String? {
		return jws.header.kid
	}

	let allegedFormat: Int
	let allegedCipherCombo: String
	public var allegedHubConfig: HubConfig? {
		return jws.header.hubConfig
	}

	private let token: Data
	private let jws: JWS

	/**
	 Decodes a vault configuration stored in JWT format.

	 - Parameter token: The token in JWT format.
	 - Returns: New unverified vault configuration instance.
	 */
	public init(token: Data) throws {
		self.token = token
		self.jws = try JWS(compactSerialization: token)
		let unverifiedPayload = try VaultConfigPayload.fromJSONData(data: jws.payload.data())
		self.allegedFormat = unverifiedPayload.format
		self.allegedCipherCombo = unverifiedPayload.cipherCombo
	}

	/**
	 Verifies signature of vault configuration.

	 - Parameter rawKey: The key matching the ID in `keyId`.
	 - Returns: Verified vault configuration instance.
	 */
	public func verify(rawKey: [UInt8]) throws -> VaultConfig {
		let supportedAlgorithms: [SignatureAlgorithm] = [.HS256, .HS384, .HS512]
		guard let algorithm = jws.header.algorithm, supportedAlgorithms.contains(where: { $0 == algorithm }) else {
			throw VaultConfigError.unsupportedAlgorithm
		}
		guard let verifier = Verifier(verifyingAlgorithm: algorithm, key: Data(rawKey)) else {
			throw VaultConfigError.signatureVerificationFailed
		}
		let verifiedJWS = try jws.validate(using: verifier)
		return try VaultConfig(jsonData: verifiedJWS.payload.data())
	}
}

public class VaultConfig {
	public let id: String
	public let format: Int
	public let cipherCombo: CryptorScheme
	public let shorteningThreshold: Int

	init(id: String, format: Int, cipherCombo: CryptorScheme, shorteningThreshold: Int) {
		self.id = id
		self.format = format
		self.cipherCombo = cipherCombo
		self.shorteningThreshold = shorteningThreshold
	}

	fileprivate convenience init(jsonData: Data) throws {
		let payload = try VaultConfigPayload.fromJSONData(data: jsonData)
		guard let cipherCombo = CryptorScheme(rawValue: payload.cipherCombo) else {
			throw VaultConfigError.unsupportedAlgorithm
		}
		self.init(id: payload.jti, format: payload.format, cipherCombo: cipherCombo, shorteningThreshold: payload.shorteningThreshold)
	}

	/**
	 Creates new configuration object for a new vault.

	 - Parameter format: Vault format number, formerly known as vault version.
	 - Parameter cipherCombo: Ciphers to use for name/content encryption.
	 - Parameter shorteningThreshold: Maximum ciphertext filename length before it gets shortened.
	 - Returns: New vault configuration instance with a random ID.
	 */
	public static func createNew(format: Int, cipherCombo: CryptorScheme, shorteningThreshold: Int) -> VaultConfig {
		return VaultConfig(id: UUID().uuidString, format: format, cipherCombo: cipherCombo, shorteningThreshold: shorteningThreshold)
	}

	/**
	 Convenience wrapper for decoding and verifying vault configuration.

	 - Parameter token: The token in JWT format.
	 - Parameter rawKey: The key matching the ID in the `token`'s `keyId`.
	 - Returns: Verified vault configuration instance.
	 */
	public static func load(token: Data, rawKey: [UInt8]) throws -> VaultConfig {
		let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)
		return try unverifiedVaultConfig.verify(rawKey: rawKey)
	}

	/**
	 Serializes vault configuration to a token in JWT format.

	 - Parameter keyId: The key ID as URI string referencing the location of the key material.
	 - Parameter rawKey: The key matching the ID in `keyId`.
	 - Returns: Signed token in JWT format.
	 */
	public func toToken(keyId: String, rawKey: [UInt8]) throws -> Data {
		let header = try JWSHeader(parameters: ["typ": "JWT", "alg": SignatureAlgorithm.HS256.rawValue, "kid": keyId])
		let payload = try VaultConfigPayload(jti: id, format: format, cipherCombo: cipherCombo.rawValue, shorteningThreshold: shorteningThreshold).toJSONData()
		guard let signer = Signer(signingAlgorithm: .HS256, key: Data(rawKey)) else {
			throw VaultConfigError.tokenSerializationFailed
		}
		let jws = try JWS(header: header, payload: Payload(payload), signer: signer)
		return jws.compactSerializedData
	}
}

extension JWSHeader {
	var hubConfig: HubConfig? {
		guard let hub = parameters["hub"] as? [String: String] else {
			return nil
		}
		guard let json = try? JSONEncoder().encode(hub) else {
			return nil
		}
		return try? JSONDecoder().decode(HubConfig.self, from: json)
	}
}
