//
//  VaultFormat7ShortenedNameCache.swift
//  CryptomatorCloudAccess
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

struct VaultFormat7ShorteningResult {
	let cloudPath: CloudPath
	let c9sDir: C9SDir?
	var pointsToC9S: Bool { cloudPath == c9sDir?.cloudPath }
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
		precondition(count > 0)
		var lastPathComponents: [String] = []
		var cloudPath = self
		for _ in 1 ... count {
			lastPathComponents.append(cloudPath.lastPathComponent)
			cloudPath = cloudPath.deletingLastPathComponent()
		}
		return lastPathComponents
	}

	func appendingPathComponents(_ pathComponents: [String]) -> CloudPath {
		if pathComponents.count == 1 {
			return appendingPathComponent(pathComponents[0])
		} else {
			let remainingComponents = Array(pathComponents[1...])
			return appendingPathComponent(pathComponents[0]).appendingPathComponents(remainingComponents)
		}
	}

	func deletingLastPathComponents(_ count: Int) -> CloudPath {
		precondition(count >= 0)
		if count == 0 {
			return self
		} else {
			return deletingLastPathComponents(count - 1).deletingLastPathComponent()
		}
	}

	func replacingPathComponent(at index: Int, with replacement: String) -> CloudPath {
		let components = path.components(separatedBy: "/")
		precondition(index < components.count)
		let tailSize = components.count - index
		assert(tailSize > 0)
		var tail = Array(components[(components.count - tailSize)...])
		tail[0] = replacement
		let prefix = Array(components[..<(components.count - tailSize)])
		return CloudPath((prefix + tail).joined(separator: "/"))
	}

	func trimmingToPathComponent(at index: Int) -> CloudPath {
		let components = path.components(separatedBy: "/")
		precondition(index < components.count)
		let toBeRemoved = components.count - components.index(after: index)
		assert(toBeRemoved >= 0)
		let remainingComponents = Array(components[..<(components.count - toBeRemoved)])
		return CloudPath(remainingComponents.joined(separator: "/"))
	}
}

class VaultFormat7ShortenedNameCache {
	private static let c9sSuffix = ".c9s"

	private let vaultPath: CloudPath
	private let threshold: Int
	private let ciphertextNameCompIdx: Int
	private let inMemoryDB: DatabaseQueue

	init(vaultPath: CloudPath, threshold: Int) throws {
		self.vaultPath = vaultPath
		self.threshold = threshold
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
	 - Returns: A `VaultFormat7ShorteningResult` object that is either based on the `originalPath` (if no shortening is required) or a shortened path.
	 */
	func getShortenedPath(_ originalPath: CloudPath) -> VaultFormat7ShorteningResult {
		if originalPath.pathComponents.count <= ciphertextNameCompIdx {
			return VaultFormat7ShorteningResult(cloudPath: originalPath, c9sDir: nil)
		}
		let originalName = originalPath.pathComponents[ciphertextNameCompIdx]
		if originalName.count > threshold {
			let shortenedName = deflateName(originalName) + VaultFormat7ShortenedNameCache.c9sSuffix
			let shortenedPath = deflatePath(originalPath, with: shortenedName)
			let c9sDirPath = shortenedPath.trimmingToPathComponent(at: ciphertextNameCompIdx)
			let c9sDir = C9SDir(cloudPath: c9sDirPath, originalName: originalName)
			try? addToCache(shortenedName, originalName: originalName)
			return VaultFormat7ShorteningResult(cloudPath: shortenedPath, c9sDir: c9sDir)
		} else {
			return VaultFormat7ShorteningResult(cloudPath: originalPath, c9sDir: nil)
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
		if shortenedPath.pathComponents.count <= ciphertextNameCompIdx {
			return Promise(shortenedPath)
		}
		let shortenedName = shortenedPath.pathComponents[ciphertextNameCompIdx]
		if shortenedName.hasSuffix(VaultFormat7ShortenedNameCache.c9sSuffix) {
			let cutOff = shortenedPath.pathComponents.count - ciphertextNameCompIdx - 1
			let c9sDirPath = shortenedPath.deletingLastPathComponents(cutOff)
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
