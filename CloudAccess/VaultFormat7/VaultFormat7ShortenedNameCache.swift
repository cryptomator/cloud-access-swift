//
//  VaultFormat7ShortenedNameCache.swift
//  CloudAccess
//
//  Created by Sebastian Stenzel on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CommonCrypto
import Foundation
import GRDB
import Promises

struct C9SDir {
	let url: URL
	let originalName: String
}

struct ShorteningResult {
	let url: URL
	let c9sDir: C9SDir?
	var pointsToC9S: Bool { url.path == c9sDir?.url.path }
}

private struct CachedEntry: Decodable, FetchableRecord, TableRecord {
	static let databaseTableName = "entries"
	static let shortenedNameKey = "shortenedName"
	static let originalNameKey = "originalName"
	let shortenedName: String
	let originalName: String
}

extension CachedEntry: PersistableRecord {
	func encode(to container: inout PersistenceContainer) {
		container[CachedEntry.shortenedNameKey] = shortenedName
		container[CachedEntry.originalNameKey] = originalName
	}
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

class VaultFormat7ShortenedNameCache {
	static let threshold = 220
	static let c9sSuffix = ".c9s"

	let vaultURL: URL
	let ciphertextNameCompIdx: Int

	private let inMemoryDB: DatabaseQueue

	init(vaultURL: URL) throws {
		self.vaultURL = vaultURL
		self.ciphertextNameCompIdx = vaultURL.pathComponents.lastItemIndex() + 4
		self.inMemoryDB = DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: CachedEntry.databaseTableName) { table in
				table.column(CachedEntry.shortenedNameKey, .text).notNull().primaryKey()
				table.column(CachedEntry.originalNameKey, .text).notNull()
			}
		}
	}

	/**
	 Applies the `.c9s` shortening defined in vault format 7 (if required).
	 This **does not** persist the original name to `name.c9s`, though.

	 - Parameter originalURL: The unshortened URL.
	 - Returns: A `ShorteningResult` object that is either based on the `originalURL` (if no shortening is required) or a shortened URL.
	 */
	func getShortenedURL(_ originalURL: URL) -> ShorteningResult {
		if originalURL.pathComponents.count <= ciphertextNameCompIdx {
			return ShorteningResult(url: originalURL, c9sDir: nil)
		}
		let originalName = originalURL.pathComponents[ciphertextNameCompIdx]
		if originalName.count > VaultFormat7ShortenedNameCache.threshold {
			let shortenedName = deflateFileName(originalName) + VaultFormat7ShortenedNameCache.c9sSuffix
			let shortenedURL = replaceCiphertextFileNameInURL(originalURL, with: shortenedName)
			let c9sDirURL = shortenedURL.trimmingToPathComponent(atIndex: ciphertextNameCompIdx).directoryURL()
			let c9sDir = C9SDir(url: c9sDirURL, originalName: originalName)
			try? addToCache(shortenedName, originalName: originalName)
			return ShorteningResult(url: shortenedURL, c9sDir: c9sDir)
		} else {
			return ShorteningResult(url: originalURL, c9sDir: nil)
		}
	}

	/**
	 Undos `.c9s` shortening defined in vault format 7 (if required).

	 - Parameter shortenedURL: A potentially shortened URL.
	 - Parameter nameC9SLoader: A closure loading the contents of a `name.c9s` file for the corresponding `c9sDirURL`.
	 - Parameter c9sDirURL: The URL of a `.c9s` directory, whose original name should be loaded.
	 - Returns: Either `shortenedURL` if no shortening was applied or the original ("inflated") URL.
	 */
	func getOriginalURL(_ shortenedURL: URL, nameC9SLoader loadNameC9S: (_ c9sDirURL: URL) -> Promise<Data>) -> Promise<URL> {
		if shortenedURL.pathComponents[ciphertextNameCompIdx].hasSuffix(VaultFormat7ShortenedNameCache.c9sSuffix) {
			let cutOff = shortenedURL.pathComponents.count - ciphertextNameCompIdx - 1
			let c9sDirURL = shortenedURL.deletingLastPathComponents(cutOff)
			let originalNamePromise = { () -> Promise<String> in
				let shortenedName = c9sDirURL.lastPathComponent
				if let originalName = try? getCached(shortenedName) {
					return Promise(originalName)
				} else {
					return loadNameC9S(c9sDirURL).then { data -> String in
						let originalName = String(data: data, encoding: .utf8)!
						try? self.addToCache(shortenedName, originalName: originalName)
						return originalName
					}
				}
			}()
			return originalNamePromise.then { originalName in
				return shortenedURL.replacingPathComponent(atIndex: self.ciphertextNameCompIdx, with: originalName, isDirectory: shortenedURL.hasDirectoryPath)
			}
		} else {
			return Promise(shortenedURL)
		}
	}

	// MARK: - Internal

	private func deflateFileName(_ inflatedName: String) -> String {
		let bytes = [UInt8](inflatedName.precomposedStringWithCanonicalMapping.utf8)
		var digest = [UInt8](repeating: 0x00, count: Int(CC_SHA1_DIGEST_LENGTH))
		CC_SHA1(bytes, UInt32(bytes.count) as CC_LONG, &digest)
		return Data(digest).base64UrlEncodedString()
	}

	func replaceCiphertextFileNameInURL(_ url: URL, with replacement: String) -> URL {
		return url.replacingPathComponent(atIndex: ciphertextNameCompIdx, with: replacement, isDirectory: url.hasDirectoryPath)
	}

	func addToCache(_ shortenedName: String, originalName: String) throws {
		try inMemoryDB.write { db in
			try CachedEntry(shortenedName: shortenedName, originalName: originalName).save(db)
		}
	}

	func getCached(_ shortenedName: String) throws -> String? {
		let entry: CachedEntry? = try inMemoryDB.read { db in
			return try CachedEntry.fetchOne(db, key: shortenedName)
		}
		return entry?.originalName
	}
}
