//
//  DirectoryIdCache.swift
//  CryptomatorCloudAccess
//
//  Created by Sebastian Stenzel on 15.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

private struct CachedEntry: Decodable, FetchableRecord, TableRecord {
	static let databaseTableName = "entries"
	static let cleartextPathKey = "cleartextPath"
	static let dirIdKey = "dirId"
	let cleartextPath: String
	let dirId: Data
}

extension CachedEntry: PersistableRecord {
	func encode(to container: inout PersistenceContainer) throws {
		container[CachedEntry.cleartextPathKey] = cleartextPath
		container[CachedEntry.dirIdKey] = dirId
	}
}

/// Caches the dir IDs of cleartext paths. It keys a path by its NFC form, because the cryptor encrypts a name in that form, so canonically equivalent spellings of a path name the same folder.
final class DirectoryIdCache: Sendable {
	/// The dir IDs of a folder and of the folders that contain it, read from their dir files by `verifiedDirectory(_:readDirId:treatingAsMissing:)`.
	struct VerifiedDirectory {
		/// The dir ID of the folder's parent.
		let parentDirId: Data
		/// The folder's own dir ID, or `nil` if reading its dir file failed with an error that counts as missing.
		let dirId: Data?
		/// The dir IDs of the vault root and of the folder's ancestors.
		let containingDirIds: Set<Data>
	}

	private let inMemoryDB: DatabaseQueue

	init() throws {
		self.inMemoryDB = try DatabaseQueue()
		try inMemoryDB.write { db in
			try db.create(table: CachedEntry.databaseTableName) { table in
				table.column(CachedEntry.cleartextPathKey, .text).notNull().primaryKey()
				table.column(CachedEntry.dirIdKey, .blob).notNull()
			}
			try CachedEntry(cleartextPath: "/", dirId: Data([])).save(db)
		}
	}

	func get(_ cleartextPath: CloudPath, onMiss: @Sendable (_ cleartextPath: CloudPath, _ parentDirId: Data) async throws -> Data) async throws -> Data {
		if let cached = try get(cleartextPath) {
			return cached
		}
		let parentDirId = try await get(cleartextPath.deletingLastPathComponent(), onMiss: onMiss)
		let dirId = try await onMiss(cleartextPath, parentDirId)
		try addOrUpdate(cleartextPath, dirId: dirId)
		return dirId
	}

	/**
	 Reads the dir IDs of a folder and of its ancestors from their dir files, bypassing this cache, and checks each against the cached one and against the dir IDs of the folders that contain it before caching it. A caller thereby learns when a dir file names a different directory than the cached one, e.g., after another device moved the folder away and created a new one at its path. A provider that resolves paths through cached item IDs can still read a moved dir file, though.

	 Cancellation is checked after each read, so that a call cancelled during a read throws without changing the cache, even if the read succeeded, and a caller can commit right after it returns.

	 - Parameter isMissing: Whether an error of reading the folder's own dir file means that the folder has none, e.g., because it's gone.
	 - Throws: `CloudProviderError.parentFolderDoesNotExist` if reading an ancestor's dir file throws `CloudProviderError.itemNotFound`. `CloudProviderError.itemNotFound` if the cache holds another dir ID for a path, after invalidating the path and its descendants, so that the caller looks the folder up again. `VaultFormatError.invalidDirectoryReference` if a dir ID repeats the root's or an ancestor's, or if the path isn't absolute or doesn't name a folder below the root (e.g., `/` or `/..`). The other errors of a read unchanged.
	 */
	func verifiedDirectory(_ cleartextPath: CloudPath, readDirId: @Sendable (_ cleartextPath: CloudPath, _ parentDirId: Data) async throws -> Data, treatingAsMissing isMissing: (Error) -> Bool) async throws -> VerifiedDirectory {
		guard cleartextPath.isResolvable, cleartextPath != .root else {
			throw VaultFormatError.invalidDirectoryReference
		}
		var containingDirIds = [Data()]
		var ancestorPath = CloudPath.root
		for component in cleartextPath.pathComponents.dropFirst().dropLast() {
			ancestorPath = ancestorPath.appendingPathComponent(component)
			let dirId: Data
			do {
				dirId = try await readDirId(ancestorPath, containingDirIds[containingDirIds.count - 1])
			} catch CloudProviderError.itemNotFound {
				throw CloudProviderError.parentFolderDoesNotExist
			}
			try addVerified(ancestorPath, dirId: dirId, containingDirIds: containingDirIds)
			containingDirIds.append(dirId)
		}
		let parentDirId = containingDirIds[containingDirIds.count - 1]
		let dirId: Data?
		do {
			dirId = try await readDirId(cleartextPath, parentDirId)
		} catch where isMissing(error) {
			dirId = nil
		}
		if let dirId {
			try addVerified(cleartextPath, dirId: dirId, containingDirIds: containingDirIds)
		} else {
			try Task.checkCancellation()
		}
		return VerifiedDirectory(parentDirId: parentDirId, dirId: dirId, containingDirIds: Set(containingDirIds))
	}

	/// Caches a dir ID that was just read from its dir file, after checking cancellation, the cached dir ID and the containing dir IDs as `verifiedDirectory` documents.
	private func addVerified(_ cleartextPath: CloudPath, dirId: Data, containingDirIds: [Data]) throws {
		try Task.checkCancellation()
		if let cached = try get(cleartextPath), cached != dirId {
			try invalidate(cleartextPath)
			throw CloudProviderError.itemNotFound
		}
		guard !containingDirIds.contains(dirId) else {
			throw VaultFormatError.invalidDirectoryReference
		}
		try addOrUpdate(cleartextPath, dirId: dirId)
	}

	func get(_ cleartextPath: CloudPath) throws -> Data? {
		let entry: CachedEntry? = try inMemoryDB.read { db in
			return try CachedEntry.fetchOne(db, key: key(cleartextPath))
		}
		return entry?.dirId
	}

	func addOrUpdate(_ cleartextPath: CloudPath, dirId: Data) throws {
		try inMemoryDB.write { db in
			try CachedEntry(cleartextPath: key(cleartextPath), dirId: dirId).save(db)
		}
	}

	/// Removes the directory ID of the path and those of its descendants.
	func invalidate(_ cleartextPath: CloudPath) throws {
		try inMemoryDB.write { db in
			_ = try CachedEntry.filter(CloudPathSubtree.condition(Column(CachedEntry.cleartextPathKey), path: key(cleartextPath))).deleteAll(db)
		}
	}

	private func key(_ cleartextPath: CloudPath) -> String {
		return cleartextPath.path.precomposedStringWithCanonicalMapping
	}
}
