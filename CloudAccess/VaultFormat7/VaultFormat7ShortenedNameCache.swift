//
//  VaultFormat7ShortenedNameCache.swift
//  CloudAccess
//
//  Created by Sebastian Stenzel on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CommonCrypto
import Foundation
import Promises

struct ShortenedURL {
	let url: URL
	let originalName: String
	let state: ShorteningState
	let nameFileURL: URL?
}

enum ShorteningState {
	/**
	 URL has not been shortened
	 */
	case unshortened

	/**
	 URL has been shortened in its last path component
	 */
	case shortenedChild

	/**
	 URL has been shortened, but not in its last path component
	 */
	case shortenedAncester
}

private extension URL {
	func lastPathComponents(_ count: Int) -> [String] {
		let comps = pathComponents
		let n = comps.count
		return Array(comps[n - count ... n - 1])
	}

	func deletingLastPathComponents(_ count: Int) -> URL {
		precondition(count >= 0)
		if count == 0 {
			return self
		} else {
			return deletingLastPathComponents(count - 1).deletingLastPathComponent()
		}
	}

	func appendingPathComponents(pathComponents: [String], isDirectory: Bool) -> URL {
		if pathComponents.count == 1 {
			return appendingPathComponent(pathComponents[0], isDirectory: isDirectory)
		} else {
			let remainingComponents = Array(pathComponents[1...])
			return appendingPathComponent(pathComponents[0]).appendingPathComponents(pathComponents: remainingComponents, isDirectory: isDirectory)
		}
	}

	func replacingPathComponent(atIndex index: Int, with replacement: String, isDirectory: Bool) -> URL {
		precondition(index < pathComponents.count)
		let tailSize = pathComponents.count - index
		assert(tailSize > 0)
		var tail = lastPathComponents(tailSize)
		let prefix = deletingLastPathComponents(tailSize)
		tail[0] = replacement
		return prefix.appendingPathComponents(pathComponents: tail, isDirectory: isDirectory)
	}
}

internal class VaultFormat7ShortenedNameCache {
	static let threshold = 220

	let vaultURL: URL
	let ciphertextNameCompIdx: Int

	init(vaultURL: URL) {
		self.vaultURL = vaultURL
		self.ciphertextNameCompIdx = vaultURL.pathComponents.endIndex - 1 + 4
	}

	/**
	 Applies the .c9s shortening defined in vault format 7 (if required).
	 This **does not** persist the original name to `name.c9s`, though.

	 - Parameter originalURL: The unshortened URL.
	 - Returns: A `ShortenedURL` object that is either based on the `originalURL` (if no shortening is required) or a shortened URL
	 */
	public func getShortenedURL(_ originalURL: URL) -> ShortenedURL {
		precondition(ciphertextNameCompIdx < originalURL.pathComponents.count)
		let originalName = originalURL.pathComponents[ciphertextNameCompIdx]
		if originalName.count > VaultFormat7ShortenedNameCache.threshold {
			let shortenedName = deflateFileName(originalName) + ".c9s"
			let shortenedURL = replaceCiphertextFileNameInURL(originalURL, with: shortenedName)
			let nameFileURL = generateNameFileURL(shortenedURL)
			let state: ShorteningState = originalURL.pathComponents.count - 1 == ciphertextNameCompIdx ? .shortenedChild : .shortenedAncester
			return ShortenedURL(url: shortenedURL, originalName: originalName, state: state, nameFileURL: nameFileURL)
		} else {
			return ShortenedURL(url: originalURL, originalName: originalName, state: .unshortened, nameFileURL: nil)
		}
	}

	/**
	 Undos .c9s shortening defined in vault format 7 (if required).

	 - Parameter shortenedURL: A potentially shortened URL.
	 - Parameter contentLoader: A closure loading the contents of `nameC9SURL`.
	 - Parameter nameC9SURL: The URL of a `name.c9s` that needs to be loaded.
	 - Returns: Either `shortenedURL` if no shortening was applied or the original ("inflated") URL
	 */
	public func getOriginalURL(_ shortenedURL: URL, contentLoader: (_ nameC9SURL: URL) -> Promise<Data>) -> Promise<URL> {
		return Promise(shortenedURL)
	}

	internal func generateNameFileURL(_ url: URL) -> URL {
		let cutOff = url.pathComponents.count - ciphertextNameCompIdx - 1
		return url.deletingLastPathComponents(cutOff).appendingPathComponent("name.c9s", isDirectory: false)
	}

	internal func replaceCiphertextFileNameInURL(_ url: URL, with replacement: String) -> URL {
		return url.replacingPathComponent(atIndex: ciphertextNameCompIdx, with: replacement, isDirectory: url.hasDirectoryPath)
	}

	private func deflateFileName(_ inflatedName: String) -> String {
		let bytes = [UInt8](inflatedName.precomposedStringWithCanonicalMapping.utf8)
		var digest = [UInt8](repeating: 0x00, count: Int(CC_SHA1_DIGEST_LENGTH))
		CC_SHA1(bytes, UInt32(bytes.count) as CC_LONG, &digest)
		return Data(digest).base64UrlEncodedString()
	}
}
