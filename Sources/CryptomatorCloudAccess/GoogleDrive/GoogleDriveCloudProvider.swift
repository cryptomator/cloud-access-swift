//
//  GoogleDriveCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 24.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

public final class GoogleDriveCloudProvider: CloudProvider {
	private static let metadataFields = "name,modifiedTime,size,mimeType"
	private static let listingFields = "nextPageToken,files(id,name,modifiedTime,size,mimeType,shortcutDetails)"
	private static let shortcutTargetFields = "modifiedTime,size,mimeType"
	private static let lookupFields = "files(id,name,mimeType,shortcutDetails)"
	private static let moveFields = "id,name,modifiedTime,mimeType,shortcutDetails"

	private let client: GoogleDriveClient
	private let identifierCache: IdentifierCache<GoogleDriveItem>
	private let maxPageSize: Int

	init(client: GoogleDriveClient, maxPageSize: Int = .max) throws {
		self.client = client
		self.identifierCache = try IdentifierCache<GoogleDriveItem>()
		let maxAllowedItemLimit = 1000
		self.maxPageSize = min(max(1, maxPageSize), maxAllowedItemLimit)
	}

	public convenience init(credential: GoogleDriveCredential, maxPageSize: Int = .max) throws {
		try self.init(client: .foreground(tokenSource: credential.tokenSource), maxPageSize: maxPageSize)
	}

	/**
	 Creates a Google Drive provider whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.

	 - Parameter sharedContainerIdentifier: The container into which the background URL session downloads files, which an app extension must share with its app, or `nil` in the app.
	 */
	public static func withBackgroundSession(credential: GoogleDriveCredential, maxPageSize: Int = .max, sessionIdentifier: String, sharedContainerIdentifier: String?) throws -> GoogleDriveCloudProvider {
		return try GoogleDriveCloudProvider(client: .background(tokenSource: credential.tokenSource, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier), maxPageSize: maxPageSize)
	}

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		return try await fetchItemMetadata(for: item)
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		return try await fetchItemList(for: item, pageToken: pageToken)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let phases = Progress.phases(of: progress, 999)
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		let metadata = try await downloadFile(for: item, to: localURL, progress: phases[0], onTaskCreation: onTaskCreation)
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		var isDirectory: ObjCBool = false
		let fileExists = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
		if !fileExists {
			throw CloudProviderError.itemNotFound
		}
		if isDirectory.boolValue {
			throw CloudProviderError.itemTypeMismatch
		}
		let phases = Progress.phases(of: progress, 999)
		let parentItem = try await resolveParentPath(forItemAt: cloudPath)
		let metadata = try await uploadFile(for: parentItem, from: localURL, to: cloudPath, replaceExisting: replaceExisting, progress: phases[0], onTaskCreation: onTaskCreation)
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		if try await checkForItemExistence(at: cloudPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let parentItem = try await resolveParentPath(forItemAt: cloudPath)
		try Task.checkCancellation()
		try await createFolder(for: parentItem, with: cloudPath.lastPathComponent)
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await deleteItem(at: cloudPath)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await deleteItem(at: cloudPath)
	}

	private func deleteItem(at cloudPath: CloudPath) async throws {
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		try await deleteItem(for: item)
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		if try await checkForItemExistence(at: targetCloudPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let item = try await resolvePath(forItemAt: sourceCloudPath)
		try await moveItem(for: item, from: sourceCloudPath, to: targetCloudPath)
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: GoogleDriveItem) async throws -> CloudItemMetadata {
		return try await perform("fetchItemMetadata(for: \(item.identifier))") {
			let file = try await client.file(id: item.resolvedIdentifier, fields: GoogleDriveCloudProvider.metadataFields)
			try identifierCache.addOrUpdate(item)
			return try convertToCloudItemMetadata(file, at: item.cloudPath)
		}
	}

	private func fetchItemList(for item: GoogleDriveItem, pageToken: String?) async throws -> CloudItemList {
		guard item.resolvedItemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
		return try await perform("fetchItemList(for: \(item.identifier), pageToken: \(pageToken ?? "nil"))") {
			let fileList: GoogleDriveFileList
			do {
				fileList = try await client.files(query: GoogleDriveClient.query(inFolder: item.resolvedIdentifier), pageSize: maxPageSize, pageToken: pageToken, fields: GoogleDriveCloudProvider.listingFields)
			} catch GoogleDriveError.apiError(statusCode: 400, _, _) where pageToken != nil {
				throw CloudProviderError.pageTokenInvalid
			}
			var items = [CloudItemMetadata]()
			for file in fileList.files ?? [] {
				guard let name = file.name else {
					throw GoogleDriveError.missingItemName
				}
				let child = try GoogleDriveItem(cloudPath: item.cloudPath.appendingPathComponent(name), file: file)
				try identifierCache.addOrUpdate(child)
				guard let shortcut = child.shortcut else {
					try items.append(convertToCloudItemMetadata(file, at: child.cloudPath))
					continue
				}
				try Task.checkCancellation()
				do {
					try await items.append(resolveShortcut(shortcut, at: child.cloudPath))
				} catch let error where GoogleDriveCloudProvider.isTargetUnavailable(error) {
					// A shortcut whose target is unavailable is left out. Any other failure fails the listing, which would otherwise look complete without the shortcut.
					continue
				}
			}
			return CloudItemList(items: items, nextPageToken: fileList.nextPageToken)
		}
	}

	private func downloadFile(for item: GoogleDriveItem, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		guard item.resolvedItemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		let remoteMetadata = try await fetchItemMetadata(for: item)
		try Task.checkCancellation()
		return try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			try await perform("downloadFile(for: \(item.identifier), to: \(localURL))") {
				try await client.download(fileID: item.resolvedIdentifier, to: stagedFile, progress: progress, onTaskCreation: onTaskCreation)
			}
			return remoteMetadata
		})
	}

	// swiftlint:disable:next function_parameter_count
	private func uploadFile(for parentItem: GoogleDriveItem, from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		let existingItem: GoogleDriveItem?
		do {
			let item = try await resolvePath(forItemAt: cloudPath)
			if !replaceExisting || item.resolvedItemType == .folder {
				throw CloudProviderError.itemAlreadyExists
			}
			existingItem = item
		} catch CloudProviderError.itemNotFound {
			existingItem = nil
		}
		try Task.checkCancellation()
		return try await perform("uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path))") {
			let file = try await client.upload(from: localURL, name: cloudPath.lastPathComponent, parentID: parentItem.resolvedIdentifier, existingFileID: existingItem?.resolvedIdentifier, progress: progress, onTaskCreation: onTaskCreation)
			// The cache keeps a replaced shortcut at its path, so that deleting the path deletes the shortcut, not the target that received the content.
			try identifierCache.addOrUpdate(existingItem ?? GoogleDriveItem(cloudPath: cloudPath, file: file))
			return try convertToCloudItemMetadata(file, at: cloudPath)
		}
	}

	private func createFolder(for parentItem: GoogleDriveItem, with name: String) async throws {
		try await perform("createFolder(for: \(parentItem.identifier), with: \(name))") {
			let folder = try await withoutCancellation {
				try await self.client.createFolder(name: name, parentID: parentItem.resolvedIdentifier)
			}
			try identifierCache.addOrUpdate(GoogleDriveItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), file: folder))
		}
	}

	/// Deletes a shortcut itself, not its target.
	private func deleteItem(for item: GoogleDriveItem) async throws {
		try await perform("deleteItem(for: \(item.identifier))") {
			try await withoutCancellation {
				try await self.client.delete(id: item.identifier)
			}
			try identifierCache.invalidate(item)
		}
	}

	/// Moves a shortcut itself, not its target, and moves out of and into the target of a shortcut to a folder.
	private func moveItem(for sourceItem: GoogleDriveItem, from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		var addParents: String?
		var removeParents: String?
		if !onlyItemNameChangedBetween(sourceCloudPath, and: targetCloudPath) {
			let oldParentItem = try await resolveParentPath(forItemAt: sourceCloudPath)
			let newParentItem = try await resolveParentPath(forItemAt: targetCloudPath)
			addParents = newParentItem.resolvedIdentifier
			removeParents = oldParentItem.resolvedIdentifier
		}
		try Task.checkCancellation()
		try await perform("moveItem(for: \(sourceItem.identifier), from: \(sourceCloudPath.path), to: \(targetCloudPath.path))") { [addParents, removeParents] in
			let file = try await withoutCancellation {
				try await self.client.update(id: sourceItem.identifier, name: targetCloudPath.lastPathComponent, addParents: addParents, removeParents: removeParents, fields: GoogleDriveCloudProvider.moveFields)
			}
			try identifierCache.invalidate(sourceItem)
			try identifierCache.addOrUpdate(GoogleDriveItem(cloudPath: targetCloudPath, file: file))
		}
	}

	// MARK: - Resolve Path

	private func resolvePath(forItemAt cloudPath: CloudPath) async throws -> GoogleDriveItem {
		return try await identifierCache.resolvePath(forItemAt: cloudPath, lookUpChild: getGoogleDriveItem(name:parentItem:))
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) async throws -> GoogleDriveItem {
		return try await identifierCache.resolveParentPath(forItemAt: cloudPath, lookUpChild: getGoogleDriveItem(name:parentItem:))
	}

	/**
	 Searches the folder belonging to `parentItem.identifier` for an item with the same `name`.

	 This is necessary because Google Drive does not use normal paths, but only works with (parent-)identifiers.

	 Shortcuts are supported by resolving them transparently to the target.

	 Workaround for cyrillic names: https://stackoverflow.com/a/47282129/1759462
	 */
	private func getGoogleDriveItem(name: String, parentItem: GoogleDriveItem) async throws -> GoogleDriveItem {
		let fileList = try await perform("getGoogleDriveItem(name: \(name), parentItem: \(parentItem.identifier))") {
			try await client.files(query: GoogleDriveClient.query(inFolder: parentItem.resolvedIdentifier, named: name), pageSize: nil, pageToken: nil, fields: GoogleDriveCloudProvider.lookupFields)
		}
		guard let file = fileList.files?.first(where: { $0.name == name }) else {
			throw CloudProviderError.itemNotFound
		}
		return try GoogleDriveItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), file: file)
	}

	// MARK: - Resolve Shortcut

	private func resolveShortcut(_ shortcut: GoogleDriveShortcut, at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: resolveShortcut(\(shortcut.targetIdentifier), at: \(cloudPath.path)) called")
		let file = try await client.file(id: shortcut.targetIdentifier, fields: GoogleDriveCloudProvider.shortcutTargetFields)
		return try convertToCloudItemMetadata(file, at: cloudPath)
	}

	// MARK: - Helpers

	/// Checks whether a shortcut's target can't be read because it was deleted or isn't shared with the user.
	private static func isTargetUnavailable(_ error: Error) -> Bool {
		switch error {
		case GoogleDriveError.apiError(statusCode: 404, _, _):
			return true
		case let GoogleDriveError.apiError(statusCode: 403, reason, _):
			return !GoogleDriveError.isRetryable(statusCode: 403, reason: reason)
		default:
			return false
		}
	}

	private func convertToCloudItemMetadata(_ file: GoogleDriveFile, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		return try CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: file.cloudItemType, lastModifiedDate: file.lastModifiedDate, size: file.sizeValue)
	}

	/// Logs the operation and converts the errors that it throws.
	private func perform<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: \(operation) called")
		do {
			return try await body()
		} catch {
			CloudAccessDDLogDebug("GoogleDriveCloudProvider: \(operation) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	func convertStandardError(_ error: Error) -> Error {
		switch error {
		case _ where isCancellationError(error):
			return CancellationError()
		case GoogleDriveError.apiError(statusCode: 403, reason: "storageQuotaExceeded", _):
			return CloudProviderError.quotaInsufficient
		case let GoogleDriveError.apiError(statusCode: 403, reason, _) where GoogleDriveError.isRetryable(statusCode: 403, reason: reason):
			// The requests were retried until no attempt was left, and a rate limit is no login failure.
			return error
		case GoogleDriveError.apiError(statusCode: 401, _, _), GoogleDriveError.apiError(statusCode: 403, _, _):
			return CloudProviderError.unauthorized
		case GoogleDriveError.apiError(statusCode: 404, _, _):
			return CloudProviderError.itemNotFound
		case GoogleDriveError.apiError(statusCode: 507, _, _):
			// This has never been verified and Google Drive API documentation is sparse.
			return CloudProviderError.quotaInsufficient
		default:
			return error
		}
	}

	func onlyItemNameChangedBetween(_ lhs: CloudPath, and rhs: CloudPath) -> Bool {
		let lhsWithoutItemName = lhs.deletingLastPathComponent()
		let rhsWithoutItemName = rhs.deletingLastPathComponent()
		return lhsWithoutItemName == rhsWithoutItemName
	}
}
