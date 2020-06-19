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

struct C9SDir {
	let url: URL
	let originalName: String
}

struct ShorteningResult {
	let url: URL
	let c9sDir: C9SDir?
	// TODO fuck that additional "isDirectory" crap -.-
	var pointsToC9S: Bool { url.appendingPathComponent(".", isDirectory: true) == c9sDir?.url.appendingPathComponent(".", isDirectory: true) }
}

private extension Array {
	func lastItemIndex() -> Int {
		return index(before: endIndex)
	}
}

private extension URL {
	func lastPathComponents(_ count: Int) -> [String] {
		let comps = pathComponents
		let n = comps.count
		return Array(comps[n - count ... n - 1])
	}

	func directoryURL() -> URL {
		return deletingLastPathComponent().appendingPathComponent(lastPathComponent, isDirectory: true)
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

	func trimmingToPathComponent(atIndex index: Int) -> URL {
		let toBeRemoved = pathComponents.count - pathComponents.index(after: index)
		return deletingLastPathComponents(toBeRemoved)
	}
}

internal class VaultFormat7ShortenedNameCache {
	static let threshold = 220
	static let c9sSuffix = ".c9s"

	let vaultURL: URL
	let ciphertextNameCompIdx: Int

	init(vaultURL: URL) {
		self.vaultURL = vaultURL
		self.ciphertextNameCompIdx = vaultURL.pathComponents.lastItemIndex() + 4
	}

	/**
	 Applies the .c9s shortening defined in vault format 7 (if required).
	 This **does not** persist the original name to `name.c9s`, though.

	 - Parameter originalURL: The unshortened URL.
	 - Returns: A `ShortenedURL` object that is either based on the `originalURL` (if no shortening is required) or a shortened URL
	 */
	public func getShortenedURL(_ originalURL: URL) -> ShorteningResult {
		if originalURL.pathComponents.count <= ciphertextNameCompIdx {
			return ShorteningResult(url: originalURL, c9sDir: nil)
		}
		let originalName = originalURL.pathComponents[ciphertextNameCompIdx]
		if originalName.count > VaultFormat7ShortenedNameCache.threshold {
			let shortenedName = deflateFileName(originalName) + VaultFormat7ShortenedNameCache.c9sSuffix
			let shortenedURL = replaceCiphertextFileNameInURL(originalURL, with: shortenedName)
			let c9sURL = shortenedURL.trimmingToPathComponent(atIndex: ciphertextNameCompIdx).directoryURL()
			let c9sDir = C9SDir(url: c9sURL, originalName: originalName)
			return ShorteningResult(url: shortenedURL, c9sDir: c9sDir)
		} else {
			return ShorteningResult(url: originalURL, c9sDir: nil)
		}
	}

	/**
	 Undos .c9s shortening defined in vault format 7 (if required).

	 - Parameter shortenedURL: A potentially shortened URL.
	 - Parameter nameC9SLoader: A closure loading the contents of a `name.c9s` file for the corresponding `c9sDirURL`.
	 - Parameter c9sDirURL: The URL of a `.c9s` directory, whose original name should be loaded
	 - Returns: Either `shortenedURL` if no shortening was applied or the original ("inflated") URL
	 */
	public func getOriginalURL(_ shortenedURL: URL, nameC9SLoader loadNameC9S: (_ c9sDirURL: URL) -> Promise<Data>) -> Promise<URL> {
		if shortenedURL.pathComponents[ciphertextNameCompIdx].hasSuffix(VaultFormat7ShortenedNameCache.c9sSuffix) {
			let cutOff = shortenedURL.pathComponents.count - ciphertextNameCompIdx - 1
			let c9sDirURL = shortenedURL.deletingLastPathComponents(cutOff)
			return loadNameC9S(c9sDirURL).then { data -> URL in
				let name = String(data: data, encoding: .utf8)!
				return shortenedURL.replacingPathComponent(atIndex: self.ciphertextNameCompIdx, with: name, isDirectory: shortenedURL.hasDirectoryPath)
			}
		} else {
			return Promise(shortenedURL)
		}
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
