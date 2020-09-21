//
//  VaultFormat6ShortenedNameCache.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CommonCrypto
import Foundation
import GRDB
import Promises

struct VaultFormat6ShorteningResult {
	let cloudPath: CloudPath
	var pointsToLNG: Bool { cloudPath.pathExtension == "lng" }
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

class VaultFormat6ShortenedNameCache {
	private static let threshold = 129
	private static let lngSuffix = ".lng"

	private let vaultPath: CloudPath
	private let ciphertextNameCompIdx: Int
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
	 Applies the `.lng` shortening defined in vault format 6 (if required).
	 This **does not** persist the original name to the `m` directory, though.

	 - Parameter originalPath: The unshortened path.
	 - Returns: A `VaultFormat6ShorteningResult` object that is either based on the `originalPath` (if no shortening is required) or a shortened path.
	 */
	func getShortenedPath(_ originalPath: CloudPath) -> VaultFormat6ShorteningResult {
		precondition(originalPath.pathComponents.count <= ciphertextNameCompIdx + 1)
		if originalPath.pathComponents.count <= ciphertextNameCompIdx {
			return VaultFormat6ShorteningResult(cloudPath: originalPath)
		}
		let originalName = originalPath.lastPathComponent
		if originalName.count > VaultFormat6ShortenedNameCache.threshold {
			let shortenedName = deflateName(originalName) + VaultFormat6ShortenedNameCache.lngSuffix
			let shortenedPath = deflatePath(originalPath, with: shortenedName)
			try? addToCache(shortenedName, originalName: originalName)
			return VaultFormat6ShorteningResult(cloudPath: shortenedPath)
		} else {
			return VaultFormat6ShorteningResult(cloudPath: originalPath)
		}
	}

	/**
	 Undos `.lng` shortening defined in vault format 6 (if required).

	 - Parameter shortenedPath: A potentially shortened path.
	 - Parameter lngFileLoader: A closure loading the contents of a `.lng` file for the corresponding `lngFileName`.
	 - Parameter lngFileName: The name of a `.lng` file, whose original name should be loaded.
	 - Returns: Either `shortenedPath` if no shortening was applied or the original ("inflated") path.
	 */
	func getOriginalPath(_ shortenedPath: CloudPath, lngFileLoader loadLngFile: (_ lngFileName: String) -> Promise<Data>) -> Promise<CloudPath> {
		precondition(shortenedPath.pathComponents.count <= ciphertextNameCompIdx + 1)
		if shortenedPath.pathComponents.count <= ciphertextNameCompIdx {
			return Promise(shortenedPath)
		}
		let shortenedName = shortenedPath.lastPathComponent
		if shortenedName.hasSuffix(VaultFormat6ShortenedNameCache.lngSuffix) {
			return inflateName(shortenedName, lngFileLoader: loadLngFile).then { originalName in
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
		return Data(digest).base32EncodedString
	}

	func deflatePath(_ originalPath: CloudPath, with shortenedName: String) -> CloudPath {
		return originalPath.deletingLastPathComponent().appendingPathComponent(shortenedName)
	}

	private func inflateName(_ shortenedName: String, lngFileLoader loadLngFile: (_ lngFileName: String) -> Promise<Data>) -> Promise<String> {
		if let originalName = try? getCached(shortenedName) {
			return Promise(originalName)
		} else {
			return loadLngFile(shortenedName).then { data -> String in
				let originalName = String(data: data, encoding: .utf8)!
				try? self.addToCache(shortenedName, originalName: originalName)
				return originalName
			}
		}
	}

	private func inflatePath(_ shortenedPath: CloudPath, with originalName: String) -> CloudPath {
		return shortenedPath.deletingLastPathComponent().appendingPathComponent(originalName)
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
