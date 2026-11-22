//
//  IdentifierAddressedPreflight.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 22.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Resolves the paths of a provider that addresses its items by identifiers, and decides whether a mutation may proceed, before the provider sends its request.

 A target is judged by a fresh lookup in the parent folder that the write goes to, not by the item that the cache holds at its path, because another client may have moved, renamed, trashed or replaced that item. The only exception is an upload's `fastPath`, which must confirm the cached item with a request. Each method returns the items that it judged, so that the request names exactly them.

 It checks for cancellation before every request that it sends, and each `prepare…` and `resolveSource` method checks once more before it returns.
 */
struct IdentifierAddressedPreflight<Item: IdentifierCacheItem> {
	/// The items that a move names: the source, the folder that it was found in and the folder that it moves into.
	struct Move {
		let source: Item
		let sourceParent: Item
		let targetParent: Item
	}

	/// The local file of an upload, the folder that it is written into and the file that it replaces, if any.
	struct Upload {
		let file: LocalUploadFile
		let parent: Item
		let existing: Item?
	}

	let cache: IdentifierCache<Item>
	/// The name that the log lines start with.
	let providerName: String
	/// Returns the item that holds the name in the folder, or `nil` if the name is free. Throws `CloudProviderError.itemNotFound` if the provider can tell that the folder itself is gone. It must not write to the cache, because the resolution caches a found item only through the parent check, and a target check caches nothing.
	let lookUp: (_ name: String, _ folderItem: Item) async throws -> Item?

	/// Resolves the path. A path below an item that is no folder throws `CloudProviderError.itemNotFound` without a lookup in that item.
	func resolve(at cloudPath: CloudPath) async throws -> Item {
		return try await cache.resolvePath(forItemAt: cloudPath, lookUpChild: lookUpChild(named:in:))
	}

	/**
	 Resolves the source of a delete.

	 - Parameter type: `.folder` requires a folder, and `.file` a file or a symbolic link.
	 - Parameter operation: The name of the provider's method, for the log.
	 - Throws: `CloudProviderError.itemTypeMismatch` if the item is of another type.
	 */
	func resolveSource(at cloudPath: CloudPath, type: CloudItemType, operation: String) async throws -> Item {
		let item = cloudPath == .root ? try await resolve(at: cloudPath) : try await resolveWithParent(at: cloudPath).item
		try checkType(of: item, at: cloudPath, type: type, operation: operation)
		try Task.checkCancellation()
		return item
	}

	/// Resolves the folder that the new folder goes into, and throws `CloudProviderError.itemAlreadyExists` if an item holds its name.
	func prepareCreateFolder(at cloudPath: CloudPath) async throws -> Item {
		let parentItem = try await resolveTargetParent(of: cloudPath)
		if try await occupant(named: cloudPath.lastPathComponent, in: parentItem) != nil {
			throw CloudProviderError.itemAlreadyExists
		}
		try Task.checkCancellation()
		return parentItem
	}

	/**
	 Resolves the target's parent folder, then the source with its type and the folder that it was found in, then looks up the target.

	 - Throws: `Item.inconsistentCacheError` if, once the source is resolved, the target's folder is no longer the connected item at its path, or the source's folder has the target folder's path but is another item, because the move would then go into or out of a folder that left the path.
	 */
	func prepareMove(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath, type: CloudItemType, operation: String) async throws -> Move {
		guard sourceCloudPath != .root else {
			throw typeMismatch(at: sourceCloudPath, operation: operation)
		}
		guard sourceCloudPath.isResolvable else {
			throw CloudProviderError.itemNotFound
		}
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
		return Move(source: sourceItem, sourceParent: sourceParentItem, targetParent: targetParentItem)
	}

	/**
	 Reads the local file, resolves the target's parent folder and finds the file that the upload replaces, if any.

	 - Parameter fastPath: Confirms the file that the cache holds at the target, given the parent folder, or returns `nil` if it can't. It is tried only for `replaceExisting`, and a `nil` falls back to the lookup.
	 - Throws: `CloudProviderError.itemAlreadyExists` if an item holds the target's name and either `replaceExisting` is false or the item is no file.
	 */
	func prepareUpload(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, fastPath: ((_ cachedItem: Item, _ parentItem: Item) async throws -> Item?)? = nil) async throws -> Upload {
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
		return Upload(file: localFile, parent: parentItem, existing: existingItem)
	}

	// MARK: - Steps

	/// Resolves the path's parent folder. The root has none, so it throws `CloudProviderError.itemAlreadyExists` as the target that exists.
	private func resolveTargetParent(of cloudPath: CloudPath) async throws -> Item {
		guard cloudPath != .root else {
			throw CloudProviderError.itemAlreadyExists
		}
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

	/// Resolves a path below the root and reads its item together with its parent's. If the pair isn't cached and connected to the root once the path is resolved, because a concurrent write removed or replaced an item on the path, it resolves once more.
	private func resolveWithParent(at cloudPath: CloudPath) async throws -> (item: Item, parent: Item) {
		for _ in 0 ..< 2 {
			_ = try await resolve(at: cloudPath)
			if let itemWithParent = cache.itemWithParent(at: cloudPath) {
				return itemWithParent
			}
		}
		throw Item.inconsistentCacheError
	}

	private func checkType(of item: Item, at cloudPath: CloudPath, type: CloudItemType, operation: String) throws {
		let acceptedTypes: [CloudItemType] = type == .folder ? [.folder] : [.file, .symlink]
		guard acceptedTypes.contains(item.effectiveItemType) else {
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
