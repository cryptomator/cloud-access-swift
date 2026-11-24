//
//  IdentifierAddressedPreflight.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 22.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Resolves the paths of a provider that addresses its items by identifiers, and decides whether a mutation may proceed, before the provider sends its request. It also commits a move or a delete to the cache once its request returns or fails.

 A target is judged by a fresh lookup in the parent folder that the write goes to, not by the item that the cache holds at its path, because another client may have moved, renamed, trashed or replaced that item. The only exception is an upload's `fastPath`, which must confirm the cached item with a request. Each method returns the items that it judged, so that the request names exactly them.

 It checks for cancellation before every lookup that it sends, and each `prepare…` and `resolveSource` method checks once more before it returns. `commitMove` and `commitDelete` don't check, because the request is the commit point.
 */
struct IdentifierAddressedPreflight<Item: IdentifierCacheItem> {
	/// The items that a move names: the source, the folder that it was found in and the folder that it moves into, with the mark taken before they were resolved.
	struct Move {
		let source: Item
		let sourceParent: Item
		let targetParent: Item
		let changeMark: ChangeMark
	}

	/// The local file of an upload, the folder that it is written into and the file that it replaces, if any, with the mark taken before they were resolved.
	struct Upload {
		let file: LocalUploadFile
		let parent: Item
		let existing: Item?
		let changeMark: ChangeMark
	}

	/// The folder that a new folder goes into, with the mark taken before it was resolved.
	struct CreateFolder {
		let parent: Item
		let changeMark: ChangeMark
	}

	let cache: IdentifierCache<Item>
	/// The name that the log lines start with.
	let providerName: String
	/// Returns the item that holds the name in the folder, or `nil` if the name is free. Throws `CloudProviderError.itemNotFound` if the provider can tell that the folder itself is gone. It must not write to the cache, because the resolution caches a found item only through its guarded write (`IdentifierCache.addOrUpdate(_:ifStillBelow:unchangedSince:)`), and a target check caches nothing.
	let lookUp: (_ name: String, _ folderItem: Item) async throws -> Item?

	/// Resolves the path. A path below an item that is no folder throws `CloudProviderError.itemNotFound` without a lookup in that item.
	func resolve(at cloudPath: CloudPath) async throws -> Item {
		return try await cache.resolvePath(forItemAt: cloudPath, lookUpChild: lookUpChild(named:in:))
	}

	/**
	 Resolves the path and reads its item together with its parent's in one cache read. If the pair isn't cached and connected to the root once the path is resolved, because a concurrent write removed or replaced an item on the path, it resolves once more.

	 - Throws: `CloudProviderError.itemTypeMismatch` for the root, which has no parent, without a lookup, and `Item.inconsistentCacheError` if the second resolution doesn't leave the pair cached either.
	 */
	func resolveWithParent(at cloudPath: CloudPath) async throws -> (item: Item, parent: Item) {
		guard cloudPath != .root else {
			throw CloudProviderError.itemTypeMismatch
		}
		for _ in 0 ..< 2 {
			_ = try await resolve(at: cloudPath)
			if let itemWithParent = cache.itemWithParent(at: cloudPath) {
				return itemWithParent
			}
		}
		throw Item.inconsistentCacheError
	}

	/**
	 Resolves the source of a delete.

	 - Parameter type: `.folder` requires a folder, and `.file` a file or a symbolic link.
	 - Parameter operation: The name of the provider's method, for the log.
	 - Throws: `CloudProviderError.itemTypeMismatch` for the root, without a lookup, and if the item is of another type.
	 */
	func resolveSource(at cloudPath: CloudPath, type: CloudItemType, operation: String) async throws -> Item {
		guard cloudPath != .root else {
			throw typeMismatch(at: cloudPath, operation: operation)
		}
		let item = try await resolveWithParent(at: cloudPath).item
		try checkType(of: item, at: cloudPath, type: type, operation: operation)
		try Task.checkCancellation()
		return item
	}

	/// Resolves the folder that the new folder goes into, and throws `CloudProviderError.itemAlreadyExists` if an item holds its name.
	func prepareCreateFolder(at cloudPath: CloudPath) async throws -> CreateFolder {
		let changeMark = try cache.changeMark()
		let parentItem = try await resolveTargetParent(of: cloudPath)
		if try await occupant(named: cloudPath.lastPathComponent, in: parentItem) != nil {
			throw CloudProviderError.itemAlreadyExists
		}
		try Task.checkCancellation()
		return CreateFolder(parent: parentItem, changeMark: changeMark)
	}

	/**
	 Resolves the target's parent folder, then the source with its type and the folder that it was found in, then looks up the target.

	 - Throws: `Item.inconsistentCacheError` if, once the source is resolved, the target's folder is no longer the connected item at its path, or the source's folder has the target folder's path but is another item, because the move would then go into or out of a folder that left the path.
	 */
	func prepareMove(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath, type: CloudItemType, operation: String) async throws -> Move {
		let changeMark = try cache.changeMark()
		guard sourceCloudPath != .root else {
			throw typeMismatch(at: sourceCloudPath, operation: operation)
		}
		try sourceCloudPath.checkResolvable()
		let targetParentItem = try await resolveTargetParent(of: targetCloudPath)
		let (sourceItem, sourceParentItem) = try await resolveWithParent(at: sourceCloudPath)
		try checkType(of: sourceItem, at: sourceCloudPath, type: type, operation: operation)
		let isSameParentPath = sourceParentItem.cloudPath.path.utf8.elementsEqual(targetParentItem.cloudPath.path.utf8)
		guard cache.isConnected(targetParentItem), !isSameParentPath || sourceParentItem.isSameItem(as: targetParentItem) else {
			throw Item.inconsistentCacheError
		}
		if try await occupant(named: targetCloudPath.lastPathComponent, in: targetParentItem) != nil {
			throw CloudProviderError.itemAlreadyExists
		}
		try Task.checkCancellation()
		return Move(source: sourceItem, sourceParent: sourceParentItem, targetParent: targetParentItem, changeMark: changeMark)
	}

	/**
	 Sends a move's request and commits it to the cache.

	 Any error of `request` still commits the move, without a target item, because the server may have applied it. A transport failure or a response that can't be decoded or can't build the target item leaves the outcome open, and a refusal may answer a resend of an attempt that the server applied. Where the move wasn't applied, dropping the rows costs only a lookup. The request's error is rethrown unchanged. A failed write of that commit is only logged.

	 - Parameter request: Sends the move and returns the moved item at the target.
	 */
	func commitMove(_ move: Move, to targetCloudPath: CloudPath, request: () async throws -> Item) async throws {
		let targetItem: Item
		do {
			targetItem = try await request()
		} catch {
			commitAfterFailedRequest(operation: "commitMove(of: \(move.source.cloudPath.path), to: \(targetCloudPath.path))") {
				try cache.commitMove(of: move.source, to: targetCloudPath, as: nil, ifStillBelow: move.targetParent, unchangedSince: move.changeMark)
			}
			throw error
		}
		try cache.commitMove(of: move.source, to: targetCloudPath, as: targetItem, ifStillBelow: move.targetParent, unchangedSince: move.changeMark)
	}

	/**
	 Sends a delete's request and commits it to the cache.

	 Any error of `request` still commits the delete, as `commitMove(_:to:request:)` does for a move. The request's error is rethrown unchanged, and a failed write of that commit is only logged.
	 */
	func commitDelete(_ item: Item, request: () async throws -> Void) async throws {
		do {
			try await request()
		} catch {
			commitAfterFailedRequest(operation: "commitDelete(of: \(item.cloudPath.path))") {
				try cache.invalidate(item)
			}
			throw error
		}
		try cache.invalidate(item)
	}

	/**
	 Reads the local file, resolves the target's parent folder and finds the file that the upload replaces, if any.

	 - Parameter fastPath: Confirms the file that the cache holds at the target, given the parent folder, or returns `nil` if it can't. It is tried only for `replaceExisting`, and a `nil` falls back to the lookup.
	 - Throws: `CloudProviderError.itemAlreadyExists` if an item holds the target's name and either `replaceExisting` is false or the item is no file.
	 */
	func prepareUpload(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, fastPath: ((_ cachedItem: Item, _ parentItem: Item) async throws -> Item?)? = nil) async throws -> Upload {
		let changeMark = try cache.changeMark()
		let localFile = try LocalUploadFile(localURL)
		let parentItem = try await resolveTargetParent(of: cloudPath)
		var existingItem: Item?
		if replaceExisting, let fastPath, let cachedItem = cache.get(cloudPath), cachedItem.effectiveItemType == .file {
			try Task.checkCancellation()
			existingItem = try await fastPath(cachedItem, parentItem)
		}
		if existingItem == nil {
			existingItem = try await occupant(named: cloudPath.lastPathComponent, in: parentItem)
		}
		if let existingItem, !replaceExisting || existingItem.effectiveItemType != .file {
			throw CloudProviderError.itemAlreadyExists
		}
		try Task.checkCancellation()
		return Upload(file: localFile, parent: parentItem, existing: existingItem, changeMark: changeMark)
	}

	// MARK: - Steps

	/// Resolves the path's parent folder. The root has none, so it throws `CloudProviderError.itemAlreadyExists` as the target that exists.
	private func resolveTargetParent(of cloudPath: CloudPath) async throws -> Item {
		try cloudPath.checkAsTarget()
		let parentItem = try await cache.resolveParentPath(forItemAt: cloudPath, lookUpChild: lookUpChild(named:in:))
		guard parentItem.effectiveItemType == .folder else {
			throw CloudProviderError.parentFolderDoesNotExist
		}
		return parentItem
	}

	/// Looks up the item that holds the name in the folder, and throws `CloudProviderError.parentFolderDoesNotExist` if the folder is gone.
	private func occupant(named name: String, in parentItem: Item) async throws -> Item? {
		try Task.checkCancellation()
		do {
			return try await lookUp(name, parentItem)
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}

	/// Writes the commit of a failed request. A failed write is logged, so that the request's error is the one thrown.
	private func commitAfterFailedRequest(operation: String, _ write: () throws -> Void) {
		do {
			try write()
		} catch let writeError {
			CloudAccessDDLogDebug("\(providerName): \(operation) failed to clear the cache with error: \(writeError)")
		}
	}

	private func checkType(of item: Item, at cloudPath: CloudPath, type: CloudItemType, operation: String) throws {
		guard item.effectiveItemType.isTaken(byOperationOn: type) else {
			throw typeMismatch(at: cloudPath, operation: operation)
		}
	}

	private func lookUpChild(named name: String, in folderItem: Item) async throws -> Item {
		guard folderItem.effectiveItemType == .folder, let item = try await lookUp(name, folderItem) else {
			throw CloudProviderError.itemNotFound
		}
		return item
	}

	private func typeMismatch(at cloudPath: CloudPath, operation: String) -> Error {
		let error = CloudProviderError.itemTypeMismatch
		CloudAccessDDLogDebug("\(providerName): \(operation)(at: \(cloudPath.path)) failed with error: \(error)")
		return error
	}
}

extension IdentifierAddressedPreflight.Move: Sendable where Item: Sendable {}

extension IdentifierAddressedPreflight.Upload: Sendable where Item: Sendable {}

extension IdentifierAddressedPreflight.CreateFolder: Sendable where Item: Sendable {}
