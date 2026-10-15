//
//  VaultCryptor.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation

/// The cryptographic operations that the vault decorators need from a `Cryptor`.
protocol VaultCryptor: Sendable {
	var fileHeaderSize: Int { get }

	func encryptDirId(_ dirId: Data) throws -> String
	func encryptFileName(_ cleartextName: String, dirId: Data, encoding: FileNameEncoding) throws -> String
	func decryptFileName(_ ciphertextName: String, dirId: Data, encoding: FileNameEncoding) throws -> String
	@concurrent
	func encryptContent(from cleartextURL: URL, to ciphertextURL: URL, progress: Progress?) async throws
	@concurrent
	func decryptContent(from ciphertextURL: URL, to cleartextURL: URL, progress: Progress?) async throws
	func calculateCiphertextSize(_ cleartextSize: Int) -> Int
	func calculateCleartextSize(_ ciphertextSize: Int) throws -> Int
}

extension VaultCryptor {
	func encryptFileName(_ cleartextName: String, dirId: Data) throws -> String {
		return try encryptFileName(cleartextName, dirId: dirId, encoding: .base64url)
	}

	func decryptFileName(_ ciphertextName: String, dirId: Data) throws -> String {
		return try decryptFileName(ciphertextName, dirId: dirId, encoding: .base64url)
	}

	func encryptContent(from cleartextURL: URL, to ciphertextURL: URL) async throws {
		try await encryptContent(from: cleartextURL, to: ciphertextURL, progress: nil)
	}
}

extension Cryptor: VaultCryptor {}
