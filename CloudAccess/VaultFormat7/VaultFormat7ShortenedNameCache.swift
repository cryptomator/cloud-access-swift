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
	let cloudPath: CloudPath
	let originalName: String
}

struct ShorteningResult {
	let cloudPath: CloudPath
	let c9sDir: C9SDir?
	var pointsToC9S: Bool { cloudPath.standardized.path == c9sDir?.cloudPath.standardized.path }
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

private extension CloudPath {
	func lastPathComponents(_ count: Int) -> [String] {
		let components = path.components(separatedBy: "/")
		return Array(components[(components.count - count)...])
	}

	func appendingPathComponents(pathComponents: [String]) -> CloudPath {
		let components = path.components(separatedBy: "/") + pathComponents
		let path = components.joined(separator: "/")
		return CloudPath(path)
	}

	func deletingLastPathComponents(_ count: Int) -> CloudPath {
		precondition(count >= 0)
		var components = path.components(separatedBy: "/")
		components.removeLast(count)
		let path = components.joined(separator: "/")
		return CloudPath(path)
	}

	func replacingPathComponent(at index: Int, with replacement: String) -> CloudPath {
		let components = path.components(separatedBy: "/")
		precondition(index < components.count)
		let tailSize = components.count - index
		assert(tailSize > 0)
		var tail = lastPathComponents(tailSize)
		tail[0] = replacement
		let prefix = deletingLastPathComponents(tailSize)
		return prefix.appendingPathComponents(pathComponents: tail)
	}

	func trimmingToPathComponent(at index: Int) -> CloudPath {
		let components = path.components(separatedBy: "/")
		let toBeRemoved = components.count - components.index(after: index)
		return deletingLastPathComponents(toBeRemoved)
	}

	func directoryPath() -> CloudPath {
		if hasDirectoryPath {
			return self
		} else {
			return CloudPath(path + "/")
		}
	}
}

class VaultFormat7ShortenedNameCache {
	static let threshold = 220
	static let c9sSuffix = ".c9s"

	let vaultPath: CloudPath
	let ciphertextNameCompIdx: Int

	private let inMemoryDB: DatabaseQueue

	init(vaultPath: CloudPath) throws {
		self.vaultPath = vaultPath
		self.ciphertextNameCompIdx = vaultPath.pathComponents.lastItemIndex() + 4
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

	 - Parameter originalPath: The unshortened path.
	 - Returns: A `ShorteningResult` object that is either based on the `originalPath` (if no shortening is required) or a shortened path.
	 */
	func getShortenedPath(_ originalPath: CloudPath) -> ShorteningResult {
		if originalPath.pathComponents.count <= ciphertextNameCompIdx {
			return ShorteningResult(cloudPath: originalPath, c9sDir: nil)
		}
		let originalName = originalPath.pathComponents[ciphertextNameCompIdx]
		if originalName.count > VaultFormat7ShortenedNameCache.threshold {
			let shortenedName = deflateName(originalName) + VaultFormat7ShortenedNameCache.c9sSuffix
			let shortenedPath = deflatePath(originalPath, with: shortenedName)
			let c9sDirPath = shortenedPath.trimmingToPathComponent(at: ciphertextNameCompIdx).directoryPath()
			let c9sDir = C9SDir(cloudPath: c9sDirPath, originalName: originalName)
			try? addToCache(shortenedName, originalName: originalName)
			return ShorteningResult(cloudPath: shortenedPath, c9sDir: c9sDir)
		} else {
			return ShorteningResult(cloudPath: originalPath, c9sDir: nil)
		}
	}

	/**
	 Undos `.c9s` shortening defined in vault format 7 (if required).

	 - Parameter shortenedPath: A potentially shortened path.
	 - Parameter nameC9SLoader: A closure loading the contents of a `name.c9s` file for the corresponding `c9sDirPath`.
	 - Parameter c9sDirPath: The path of a `.c9s` directory, whose original name should be loaded.
	 - Returns: Either `shortenedPath` if no shortening was applied or the original ("inflated") path.
	 */
	func getOriginalPath(_ shortenedPath: CloudPath, nameC9SLoader loadNameC9S: (_ c9sDirPath: CloudPath) -> Promise<Data>) -> Promise<CloudPath> {
		if shortenedPath.pathComponents[ciphertextNameCompIdx].hasSuffix(VaultFormat7ShortenedNameCache.c9sSuffix) {
			let cutOff = shortenedPath.pathComponents.count - ciphertextNameCompIdx - 1
			let c9sDirPath = shortenedPath.deletingLastPathComponents(cutOff)
			let shortenedName = c9sDirPath.lastPathComponent
			return inflateName(shortenedName, c9sDirPath: c9sDirPath, nameC9SLoader: loadNameC9S).then { originalName in
				return self.inflatePath(shortenedPath, with: originalName)
			}
		} else {
			return Promise(shortenedPath)
		}
	}

	// MARK: - Internal

	private func deflateName(_ originalName: String) -> String {
		let bytes = [UInt8](originalName.precomposedStringWithCanonicalMapping.utf8)
		var digest = [UInt8](repeating: 0x00, count: Int(CC_SHA1_DIGEST_LENGTH))
		CC_SHA1(bytes, UInt32(bytes.count) as CC_LONG, &digest)
		return Data(digest).base64UrlEncodedString()
	}

	func deflatePath(_ originalPath: CloudPath, with shortenedName: String) -> CloudPath {
		return originalPath.replacingPathComponent(at: ciphertextNameCompIdx, with: shortenedName)
	}

	private func inflateName(_ shortenedName: String, c9sDirPath: CloudPath, nameC9SLoader loadNameC9S: (_ c9sDirPath: CloudPath) -> Promise<Data>) -> Promise<String> {
		if let originalName = try? getCached(shortenedName) {
			return Promise(originalName)
		} else {
			return loadNameC9S(c9sDirPath).then { data -> String in
				let originalName = String(data: data, encoding: .utf8)!
				try? self.addToCache(shortenedName, originalName: originalName)
				return originalName
			}
		}
	}

	private func inflatePath(_ shortenedPath: CloudPath, with originalName: String) -> CloudPath {
		return shortenedPath.replacingPathComponent(at: ciphertextNameCompIdx, with: originalName)
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
