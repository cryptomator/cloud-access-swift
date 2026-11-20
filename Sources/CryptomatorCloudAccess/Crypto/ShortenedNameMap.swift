//
//  ShortenedNameMap.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import CryptomatorCryptoLib
import Foundation
import os

/// Maps the shortened names of a vault's long ciphertext names to the names they shorten. It keys a shortened name by its UTF-8 bytes, because a listed name that is only canonically equivalent to a known one (e.g. with U+212A KELVIN SIGN for `K`) isn't that name, so its name file must be loaded and checked.
final class ShortenedNameMap: Sendable {
	private let originalNames = OSAllocatedUnfairLock(initialState: [[UInt8]: String]())

	private func originalName(forShortenedName shortenedName: String) -> String? {
		return originalNames.withLock { $0[Array(shortenedName.utf8)] }
	}

	func record(shortenedName: String, originalName: String) {
		originalNames.withLock { $0[Array(shortenedName.utf8)] = originalName }
	}

	/**
	 Returns the original name of a listed shortened name, from the map or else from its name file, whose name it then records.

	 - Parameter loadNameFile: Loads the contents of the name file.
	 - Parameter shorten: Returns the shortened name of an original name. A name file's name is accepted only if it shortens to the listed name byte for byte, because the library addresses an item by shortening its original name again.
	 - Parameter isAccepted: A further condition that a name file's name must meet.
	 - Throws: `VaultFormatError.invalidNameFile` if the name file isn't UTF-8, holds no single path component or holds a name that isn't accepted. Other failures of `loadNameFile` unchanged.
	 */
	func originalName(forShortenedName shortenedName: String, loadingNameFile loadNameFile: () async throws -> Data, shortening shorten: (String) -> String, accepting isAccepted: (String) -> Bool = { _ in true }) async throws -> String {
		if let originalName = originalName(forShortenedName: shortenedName) {
			return originalName
		}
		let data = try await loadNameFile()
		guard let originalName = String(data: data, encoding: .utf8), originalName.isSinglePathComponent, isAccepted(originalName), shorten(originalName).utf8.elementsEqual(shortenedName.utf8) else {
			throw VaultFormatError.invalidNameFile
		}
		record(shortenedName: shortenedName, originalName: originalName)
		return originalName
	}
}

/// Returns the hash that a long name shortens to, without the extension: the SHA-1 of the name's NFC form in UTF-8, in the given encoding.
func shortenedNameHash(of originalName: String, encoding: FileNameEncoding) -> String {
	let digest = Data(Insecure.SHA1.hash(data: Data(originalName.precomposedStringWithCanonicalMapping.utf8)))
	switch encoding {
	case .base32:
		return digest.base32EncodedString()
	case .base64url:
		return digest.base64UrlEncodedString()
	}
}
