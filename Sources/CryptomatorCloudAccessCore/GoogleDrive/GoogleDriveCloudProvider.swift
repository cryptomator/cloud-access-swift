//
//  GoogleDriveCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 24.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public final class GoogleDriveCloudProvider: CloudProvider {
	private typealias Preflight = IdentifierAddressedPreflight<GoogleDriveItem>

	private static let metadataFields = "name,modifiedTime,size,mimeType"
	private static let listingFields = "nextPageToken,files(id,name,modifiedTime,size,mimeType,shortcutDetails)"
	private static let shortcutTargetFields = "modifiedTime,size,mimeType"
	private static let lookupFields = "nextPageToken,files(id,name,mimeType,shortcutDetails)"
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
		let changeMark = try identifierCache.changeMark()
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		return try await fetchItemList(for: item, pageToken: pageToken, changeMark: changeMark)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let phases = Progress.phases(of: progress, 999)
		let (item, parentItem) = try await preflight.resolveWithParent(at: cloudPath)
		try Task.checkCancellation()
		let metadata = try await downloadFile(for: item, in: parentItem, to: localURL, progress: phases[0], onTaskCreation: onTaskCreation)
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let upload = try await preflight.prepareUpload(from: localURL, to: cloudPath, replaceExisting: replaceExisting)
		let phases = Progress.phases(of: progress, 999)
		let metadata = try await uploadFile(upload, to: cloudPath, progress: phases[0], onTaskCreation: onTaskCreation)
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let creation = try await preflight.prepareCreateFolder(at: cloudPath)
		try await createFolder(creation, with: cloudPath.lastPathComponent)
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let item = try await preflight.resolveSource(at: cloudPath, type: .file, operation: "deleteFile")
		try await deleteItem(for: item)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let item = try await preflight.resolveSource(at: cloudPath, type: .folder, operation: "deleteFolder")
		try await deleteItem(for: item)
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let move = try await preflight.prepareMove(from: sourceCloudPath, to: targetCloudPath, type: .file, operation: "moveFile")
		try await moveItem(move, to: targetCloudPath)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let move = try await preflight.prepareMove(from: sourceCloudPath, to: targetCloudPath, type: .folder, operation: "moveFolder")
		try await moveItem(move, to: targetCloudPath)
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: GoogleDriveItem, isAlias: Bool = false) async throws -> CloudItemMetadata {
		return try await perform("fetchItemMetadata(for: \(item.identifier))") {
			let file = try await client.file(id: item.resolvedIdentifier, fields: GoogleDriveCloudProvider.metadataFields)
			return try convertToCloudItemMetadata(file, at: item.cloudPath, isAlias: isAlias)
		}
	}

	private func fetchItemList(for item: GoogleDriveItem, pageToken: String?, changeMark: ChangeMark) async throws -> CloudItemList {
		guard item.effectiveItemType == .folder else {
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
				guard name.isSinglePathComponent else {
					CloudAccessDDLogDebug("GoogleDriveCloudProvider: skipping item \(name) in \(item.cloudPath.path), because its name is no single path component")
					continue
				}
				let child = try GoogleDriveItem(cloudPath: item.cloudPath.appendingPathComponent(name), file: file)
				try identifierCache.addOrUpdate(child, ifStillBelow: item, unchangedSince: changeMark)
				guard let shortcut = child.shortcut else {
					try items.append(convertToCloudItemMetadata(file, at: child.cloudPath, isAlias: file.mimeType == GoogleDriveJSON.shortcutMimeType))
					continue
				}
				try Task.checkCancellation()
				do {
					try await items.append(resolveShortcut(shortcut, at: child.cloudPath))
				} catch let error where isTargetUnavailable(error) {
					// A shortcut whose target is unavailable is left out. Any other failure fails the listing, which would otherwise look complete without the shortcut.
					continue
				}
			}
			return CloudItemList(items: items, nextPageToken: fileList.nextPageToken)
		}
	}

	/// Whether the item, or the cached row of the folder that holds it, is a shortcut, in which case the request reaches the shortcut's target or an item inside it.
	private func isReachedThroughShortcut(_ item: GoogleDriveItem, in parentItem: GoogleDriveItem) -> Bool {
		return item.shortcut != nil || parentItem.shortcut != nil
	}

	/// - Parameter parentItem: The cached row of the folder that holds the item, read together with the item's.
	private func downloadFile(for item: GoogleDriveItem, in parentItem: GoogleDriveItem, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		guard item.effectiveItemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		let remoteMetadata = try await fetchItemMetadata(for: item, isAlias: isReachedThroughShortcut(item, in: parentItem))
		try Task.checkCancellation()
		return try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			try await perform("downloadFile(for: \(item.identifier), to: \(localURL))") {
				try await client.download(fileID: item.resolvedIdentifier, to: stagedFile, progress: progress, onTaskCreation: onTaskCreation)
			}
			return remoteMetadata
		})
	}

	private func uploadFile(_ upload: Preflight.Upload, to cloudPath: CloudPath, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		let parentItem = upload.parent
		let localFile = upload.file
		return try await perform("uploadFile(for: \(parentItem.identifier), from: \(localFile.url), to: \(cloudPath.path))") {
			let file = try await client.upload(from: localFile, name: cloudPath.lastPathComponent, parentID: parentItem.resolvedIdentifier, existingFileID: upload.existing?.resolvedIdentifier, progress: progress, onTaskCreation: onTaskCreation)
			// The cache keeps a replaced shortcut at its path, so that deleting the path deletes the shortcut, not the target that received the content.
			try identifierCache.commitMutation(upload.existing ?? GoogleDriveItem(cloudPath: cloudPath, file: file), ifStillBelow: parentItem, unchangedSince: upload.changeMark)
			return try convertToCloudItemMetadata(file, at: cloudPath)
		}
	}

	private func createFolder(_ creation: Preflight.CreateFolder, with name: String) async throws {
		let parentItem = creation.parent
		try await perform("createFolder(for: \(parentItem.identifier), with: \(name))") {
			let folder = try await withoutCancellation {
				try await self.client.createFolder(name: name, parentID: parentItem.resolvedIdentifier)
			}
			try identifierCache.commitMutation(GoogleDriveItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), file: folder), ifStillBelow: parentItem, unchangedSince: creation.changeMark)
		}
	}

	/// Deletes a shortcut itself, not its target.
	private func deleteItem(for item: GoogleDriveItem) async throws {
		try await perform("deleteItem(for: \(item.identifier))") {
			try await preflight.commitDelete(item) {
				try await withoutCancellation {
					try await self.client.delete(id: item.identifier)
				}
			}
		}
	}

	/**
	 Moves a shortcut itself, not its target, and moves out of and into the target of a shortcut to a folder.

	 It sends no parent change if the source's folder and the target's folder resolve to the same identifier, so that a move through a shortcut to the folder that holds the item is a rename too.
	 */
	private func moveItem(_ move: Preflight.Move, to targetCloudPath: CloudPath) async throws {
		let sourceItem = move.source
		let isRename = move.sourceParent.resolvedIdentifier == move.targetParent.resolvedIdentifier
		let addParents = isRename ? nil : move.targetParent.resolvedIdentifier
		let removeParents = isRename ? nil : move.sourceParent.resolvedIdentifier
		try await perform("moveItem(for: \(sourceItem.identifier), from: \(sourceItem.cloudPath.path), to: \(targetCloudPath.path))") {
			try await preflight.commitMove(move, to: targetCloudPath) {
				let file = try await withoutCancellation {
					try await self.client.update(id: sourceItem.identifier, name: targetCloudPath.lastPathComponent, addParents: addParents, removeParents: removeParents, fields: GoogleDriveCloudProvider.moveFields)
				}
				return try GoogleDriveItem(cloudPath: targetCloudPath, file: file)
			}
		}
	}

	// MARK: - Resolve Path

	private var preflight: Preflight {
		return Preflight(cache: identifierCache, providerName: "GoogleDriveCloudProvider", lookUp: getGoogleDriveItem(name:parentItem:))
	}

	private func resolvePath(forItemAt cloudPath: CloudPath) async throws -> GoogleDriveItem {
		return try await preflight.resolve(at: cloudPath)
	}

	/**
	 Searches the folder that `parentItem` leads to (`resolvedIdentifier`) for an item named `name`, and returns `nil` if it holds none.

	 This is necessary because Google Drive does not use normal paths, but only works with (parent-)identifiers.

	 Shortcuts are supported by resolving them transparently to the target.

	 The search follows page tokens until it finds the item, because the query's `contains` also matches other names and Drive can return a short or empty page before the list ends.

	 Workaround for cyrillic names: https://stackoverflow.com/a/47282129/1759462
	 */
	private func getGoogleDriveItem(name: String, parentItem: GoogleDriveItem) async throws -> GoogleDriveItem? {
		let query = GoogleDriveClient.query(inFolder: parentItem.resolvedIdentifier, named: name)
		var pageToken: String?
		while true {
			let fileList = try await perform("getGoogleDriveItem(name: \(name), parentItem: \(parentItem.identifier), pageToken: \(pageToken ?? "nil"))") {
				try await client.files(query: query, pageSize: nil, pageToken: pageToken, fields: GoogleDriveCloudProvider.lookupFields)
			}
			if let file = fileList.files?.first(where: { $0.name == name }) {
				return try GoogleDriveItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), file: file)
			}
			guard let nextPageToken = fileList.nextPageToken else {
				return nil
			}
			try Task.checkCancellation()
			pageToken = nextPageToken
		}
	}

	// MARK: - Resolve Shortcut

	private func resolveShortcut(_ shortcut: GoogleDriveShortcut, at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: resolveShortcut(\(shortcut.targetIdentifier), at: \(cloudPath.path)) called")
		let file = try await client.file(id: shortcut.targetIdentifier, fields: GoogleDriveCloudProvider.shortcutTargetFields)
		return try convertToCloudItemMetadata(file, at: cloudPath, isAlias: true)
	}

	// MARK: - Helpers

	/**
	 Checks whether a shortcut's target request failed in a way that leaves the shortcut out of the listing: a 404, or a 403 that `convertStandardError` passes through raw and that isn't retried.

	 Such a 403 usually refuses the target itself, e.g., one that isn't shared with the user. A project's daily limit or a domain policy that begins between the folder request and the target request also leaves the shortcut out.
	 */
	private func isTargetUnavailable(_ error: Error) -> Bool {
		switch error {
		case GoogleDriveError.apiError(statusCode: 404, _, _):
			return true
		case let GoogleDriveError.apiError(statusCode: 403, reason, _):
			return !GoogleDriveError.isRetryable(statusCode: 403, reason: reason) && Self.convertStandardError(error) is GoogleDriveError
		default:
			return false
		}
	}

	private func convertToCloudItemMetadata(_ file: GoogleDriveFile, at cloudPath: CloudPath, isAlias: Bool = false) throws -> CloudItemMetadata {
		return try CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: file.cloudItemType, lastModifiedDate: file.lastModifiedDate, size: file.sizeValue, isAlias: isAlias)
	}

	/// Logs the operation and converts the errors that it throws.
	private func perform<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
		try await performLogged(operation, by: "GoogleDriveCloudProvider", convert: Self.convertStandardError, body)
	}

	static func convertStandardError(_ error: Error) -> Error {
		switch error {
		case _ where isCancellationError(error):
			return CancellationError()
		case GoogleDriveError.apiError(statusCode: 403, reason: "storageQuotaExceeded", _):
			return CloudProviderError.quotaInsufficient
		case let GoogleDriveError.apiError(statusCode: 403, reason, _) where GoogleDriveError.isRetryable(statusCode: 403, reason: reason):
			// The requests were retried until no attempt was left, and a rate limit is no login failure.
			return error
		case GoogleDriveError.apiError(statusCode: 401, _, _), GoogleDriveError.apiError(statusCode: 403, reason: "insufficientPermissions", _):
			// Google's 403 for a token without the needed scope is the only 403 that signing in again fixes. Its other 403 reasons concern an item, an action, a policy or a limit.
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
}
