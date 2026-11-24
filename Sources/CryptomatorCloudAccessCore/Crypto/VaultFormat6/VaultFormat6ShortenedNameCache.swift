//
//  VaultFormat6ShortenedNameCache.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

struct VaultFormat6ShorteningResult {
	let cloudPath: CloudPath
	let pointsToLNG: Bool
}

final class VaultFormat6ShortenedNameCache: Sendable {
	private static let threshold = 129
	private static let lngSuffix = ".lng"

	private let ciphertextNameCompIdx: Int
	private let originalNames = ShortenedNameMap()

	init(vaultPath: CloudPath) {
		self.ciphertextNameCompIdx = vaultPath.pathComponents.count + 3
	}

	/**
	 Applies the `.lng` shortening defined in vault format 6 (if required).
	 This **does not** persist the original name to the `m` directory, though.

	 - Parameter originalPath: The unshortened path.
	 - Returns: A `VaultFormat6ShorteningResult` object that is either based on the `originalPath` (if no shortening is required) or a shortened path.
	 */
	func getShortenedPath(_ originalPath: CloudPath) -> VaultFormat6ShorteningResult {
		guard needsShortening(originalPath) else {
			return VaultFormat6ShorteningResult(cloudPath: originalPath, pointsToLNG: false)
		}
		let originalName = originalPath.lastPathComponent
		let shortenedName = deflateName(originalName)
		let shortenedPath = deflatePath(originalPath, with: shortenedName)
		originalNames.record(shortenedName: shortenedName, originalName: originalName)
		return VaultFormat6ShorteningResult(cloudPath: shortenedPath, pointsToLNG: true)
	}

	/// Whether `getShortenedPath` shortens the path. Unlike it, this neither hashes the name nor records it for `getOriginalPath`.
	func needsShortening(_ originalPath: CloudPath) -> Bool {
		let pathComponents = originalPath.pathComponents
		precondition(pathComponents.count <= ciphertextNameCompIdx + 1)
		return pathComponents.count > ciphertextNameCompIdx && pathComponents[ciphertextNameCompIdx].count > VaultFormat6ShortenedNameCache.threshold
	}

	/**
	 Undos `.lng` shortening defined in vault format 6 (if required).

	 - Parameter shortenedPath: A potentially shortened path.
	 - Parameter lngFileLoader: A closure loading the contents of a `.lng` file for the corresponding `lngFileName`.
	 - Parameter lngFileName: The name of a `.lng` file, whose original name should be loaded.
	 - Returns: Either `shortenedPath` if no shortening was applied or the original ("inflated") path.
	 - Throws: `VaultFormatError.invalidNameFile` if a `.lng` name isn't 32 Base32 characters, or if its `.lng` file holds no single path component or a name whose hash isn't the `.lng` name.
	 */
	func getOriginalPath(_ shortenedPath: CloudPath, lngFileLoader loadLngFile: @Sendable (_ lngFileName: String) async throws -> Data) async throws -> CloudPath {
		precondition(shortenedPath.pathComponents.count <= ciphertextNameCompIdx + 1)
		if shortenedPath.pathComponents.count <= ciphertextNameCompIdx {
			return shortenedPath
		}
		let shortenedName = shortenedPath.lastPathComponent
		if let hash = shortenedName.removingUTF8Suffix(VaultFormat6ShortenedNameCache.lngSuffix) {
			guard VaultFormat6ShortenedNameCache.isDeflatedHash(hash) else {
				throw VaultFormatError.invalidNameFile
			}
			// Unlike in vault format 7, a name of any length is accepted, because old versions also shortened names of exactly 129 characters, which `getShortenedPath` leaves as they are.
			let originalName = try await originalNames.originalName(forShortenedName: shortenedName, loadingNameFile: { try await loadLngFile(shortenedName) }, shortening: deflateName)
			return inflatePath(shortenedPath, with: originalName)
		} else {
			return shortenedPath
		}
	}

	// MARK: - Internal

	private func deflateName(_ originalName: String) -> String {
		return shortenedNameHash(of: originalName, encoding: .base32) + VaultFormat6ShortenedNameCache.lngSuffix
	}

	/// Whether the name before `.lng` has the shape of the hash that `deflateName` puts there: 32 Base32 characters. The path of a name file is built from the first four characters of the name, so a listed name of any other shape (e.g., `..AB.lng`) could point to another directory than the one its name file belongs in.
	private static func isDeflatedHash(_ hash: String) -> Bool {
		let hash = hash.utf8
		return hash.count == 32 && hash.allSatisfy { (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains($0) || (UInt8(ascii: "2") ... UInt8(ascii: "7")).contains($0) }
	}

	func deflatePath(_ originalPath: CloudPath, with shortenedName: String) -> CloudPath {
		return originalPath.deletingLastPathComponent().appendingPathComponent(shortenedName)
	}

	private func inflatePath(_ shortenedPath: CloudPath, with originalName: String) -> CloudPath {
		return shortenedPath.deletingLastPathComponent().appendingPathComponent(originalName)
	}
}
