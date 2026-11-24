//
//  BoxCloudProvider.swift
//  CryptomatorCloudAccessCore
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import Foundation

public final class BoxCloudProvider: CloudProvider {
	private typealias Preflight = IdentifierAddressedPreflight<BoxItem>

	private static let confirmationFields = "type,id,name,parent,item_status"

	private let client: BoxClient
	private let identifierCache: IdentifierCache<BoxItem>
	private let maxPageSize: Int
	/// Box recommends uploading files of 50 MiB or more with a chunked upload.
	private let chunkedUploadThreshold: Int

	init(client: BoxClient, maxPageSize: Int, chunkedUploadThreshold: Int = 52_428_800) throws {
		self.client = client
		self.identifierCache = try IdentifierCache<BoxItem>()
		self.maxPageSize = max(1, min(maxPageSize, 1000))
		self.chunkedUploadThreshold = chunkedUploadThreshold
	}

	public convenience init(credential: BoxCredential, maxPageSize: Int = .max) throws {
		try self.init(client: .foreground(tokenSource: credential.tokenSource), maxPageSize: maxPageSize)
	}

	/**
	 Creates a Box provider whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.

	 - Parameter sharedContainerIdentifier: The container into which the background URL session downloads files, which an app extension must share with its app, or `nil` in the app.
	 */
	public static func withBackgroundSession(credential: BoxCredential, maxPageSize: Int = .max, sessionIdentifier: String, sharedContainerIdentifier: String?) throws -> BoxCloudProvider {
		return try BoxCloudProvider(client: .background(tokenSource: credential.tokenSource, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier), maxPageSize: maxPageSize)
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
		let upload = try await preflight.prepareUpload(from: localURL, to: cloudPath, replaceExisting: replaceExisting, fastPath: confirmCachedFile(_:in:))
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
		try await deleteFile(for: item)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let item = try await preflight.resolveSource(at: cloudPath, type: .folder, operation: "deleteFolder")
		try await deleteFolder(for: item)
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let move = try await preflight.prepareMove(from: sourceCloudPath, to: targetCloudPath, type: .file, operation: "moveFile")
		try await moveFile(move, to: targetCloudPath)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let move = try await preflight.prepareMove(from: sourceCloudPath, to: targetCloudPath, type: .folder, operation: "moveFolder")
		try await moveFolder(move, to: targetCloudPath)
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: BoxItem) async throws -> CloudItemMetadata {
		if item.effectiveItemType == .file {
			return try await fetchFileMetadata(for: item)
		} else if item.effectiveItemType == .folder {
			return try await fetchFolderMetadata(for: item)
		} else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("BoxCloudProvider: fetchItemMetadata(for: \(item.identifier)) failed with error: \(error)")
			throw error
		}
	}

	private func fetchFileMetadata(for item: BoxItem) async throws -> CloudItemMetadata {
		assert(item.effectiveItemType == .file)
		return try await perform("fetchFileMetadata(for: \(item.identifier))") {
			try await convertToCloudItemMetadata(client.file(id: item.identifier), at: item.cloudPath)
		}
	}

	private func fetchFolderMetadata(for item: BoxItem) async throws -> CloudItemMetadata {
		assert(item.effectiveItemType == .folder)
		return try await perform("fetchFolderMetadata(for: \(item.identifier))") {
			try await convertToCloudItemMetadata(client.folder(id: item.identifier), at: item.cloudPath)
		}
	}

	private func fetchItemList(for folderItem: BoxItem, pageToken: String?) async throws -> CloudItemList {
		guard folderItem.effectiveItemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
		return try await perform("fetchItemList(for: \(folderItem.identifier), pageToken: \(pageToken ?? "nil"))") {
			do {
				return try await convertToCloudItemList(client.folderItems(id: folderItem.identifier, marker: pageToken, limit: maxPageSize), at: folderItem.cloudPath)
			} catch BoxError.apiError(statusCode: 400, _, _) where pageToken != nil {
				throw CloudProviderError.pageTokenInvalid
			}
		}
	}

	private func downloadFile(for item: BoxItem, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		guard item.effectiveItemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		let remoteMetadata = try await fetchFileMetadata(for: item)
		try Task.checkCancellation()
		return try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			try await perform("downloadFile(for: \(item.identifier), to: \(localURL))") {
				try await client.download(fileID: item.identifier, to: stagedFile, progress: progress, onTaskCreation: onTaskCreation)
			}
			return remoteMetadata
		})
	}

	private func uploadFile(_ upload: Preflight.Upload, to cloudPath: CloudPath, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		let parentItem = upload.parent
		let localFile = upload.file
		CloudAccessDDLogDebug("BoxCloudProvider: uploadFile(for: \(parentItem.identifier), replacing: \(upload.existing?.identifier ?? "nil"), from: \(localFile.url), to: \(cloudPath)) called")
		let file: BoxEntry = switch (upload.existing, localFile.size >= chunkedUploadThreshold) {
		case let (item?, true):
			try await uploadLargeExistingFile(for: item, from: localFile, progress: progress)
		case let (item?, false):
			try await uploadSmallExistingFile(for: item, from: localFile.url, progress: progress, onTaskCreation: onTaskCreation)
		case (nil, true):
			try await uploadLargeNewFile(for: parentItem, from: localFile, to: cloudPath, progress: progress)
		case (nil, false):
			try await uploadSmallNewFile(for: parentItem, from: localFile.url, to: cloudPath, progress: progress, onTaskCreation: onTaskCreation)
		}
		let item = try BoxItem(cloudPath: cloudPath, entry: file)
		guard upload.existing != nil else {
			try identifierCache.commitMutation(item, ifStillBelow: parentItem, unchangedSince: upload.changeMark)
			return try convertToCloudItemMetadata(file, at: cloudPath)
		}
		// A new version keeps the file's name and folder, which another client can have changed while it was uploaded.
		if Self.isEntry(file, at: cloudPath, in: parentItem) {
			try identifierCache.commitMutation(item, ifStillBelow: parentItem, unchangedSince: upload.changeMark)
		} else {
			try identifierCache.commitMutation(ofItemThatLeft: item, ifStillBelow: parentItem)
		}
		return try convertToCloudItemMetadata(file, at: cloudPath, name: cloudPath.lastPathComponent)
	}

	/// Whether Box reports the entry under the path's name in the folder.
	private static func isEntry(_ entry: BoxEntry, at cloudPath: CloudPath, in parentItem: BoxItem) -> Bool {
		return entry.name == cloudPath.lastPathComponent && entry.parent?.id == parentItem.identifier
	}

	private func uploadSmallNewFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> BoxEntry {
		return try await perform("uploadSmallNewFile(for: \(parentItem.identifier), to: \(cloudPath))") {
			let files = try await client.uploadNewFile(from: localURL, name: cloudPath.lastPathComponent, parentID: parentItem.identifier, progress: progress, onTaskCreation: onTaskCreation)
			return try uploadedFile(in: files)
		}
	}

	private func uploadSmallExistingFile(for existingItem: BoxItem, from localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> BoxEntry {
		return try await perform("uploadSmallExistingFile(for: \(existingItem.identifier))") {
			let files = try await client.uploadFileVersion(from: localURL, fileID: existingItem.identifier, progress: progress, onTaskCreation: onTaskCreation)
			return try uploadedFile(in: files)
		}
	}

	private func uploadLargeNewFile(for parentItem: BoxItem, from localFile: LocalUploadFile, to cloudPath: CloudPath, progress: Progress?) async throws -> BoxEntry {
		return try await perform("uploadLargeNewFile(for: \(parentItem.identifier), to: \(cloudPath), fileSize: \(localFile.size))") {
			let uploadSession = try await client.createUploadSession(parentID: parentItem.identifier, name: cloudPath.lastPathComponent, fileSize: localFile.size)
			return try await uploadLargeFile(for: uploadSession, from: localFile, progress: progress)
		}
	}

	private func uploadLargeExistingFile(for existingItem: BoxItem, from localFile: LocalUploadFile, progress: Progress?) async throws -> BoxEntry {
		return try await perform("uploadLargeExistingFile(for: \(existingItem.identifier), fileSize: \(localFile.size))") {
			let uploadSession = try await client.createUploadSession(fileID: existingItem.identifier, fileSize: localFile.size)
			return try await uploadLargeFile(for: uploadSession, from: localFile, progress: progress)
		}
	}

	/// Uploads the parts one by one, each from a temporary file, so that no part is held in memory. The progress counts bytes, and each part gets a share of its length.
	private func uploadLargeFile(for uploadSession: BoxUploadSession, from localFile: LocalUploadFile, progress: Progress?) async throws -> BoxEntry {
		guard let uploadPartURL = uploadSession.sessionEndpoints?.uploadPart, let commitURL = uploadSession.sessionEndpoints?.commit, let partSize = uploadSession.partSize, partSize > 0 else {
			throw BoxError.unexpectedContent
		}
		progress?.totalUnitCount = localFile.size
		var fileHash = Insecure.SHA1()
		var parts = [BoxPart]()
		var offset: Int64 = 0
		let fileHandle = try FileHandle(forReadingFrom: localFile.url)
		defer {
			try? fileHandle.close()
		}
		while true {
			try Task.checkCancellation()
			var partHash = Insecure.SHA1()
			var partLength: Int64 = 0
			let partFileURL = try HTTPClientSupport.writeTemporaryFile { partHandle in
				while partLength < partSize, let chunk = try fileHandle.read(upToCount: Int(min(Int64(HTTPClientSupport.temporaryFileBufferLength), partSize - partLength))), !chunk.isEmpty {
					try partHandle.write(contentsOf: chunk)
					partHash.update(data: chunk)
					fileHash.update(data: chunk)
					partLength += Int64(chunk.count)
				}
			}
			defer {
				try? FileManager.default.removeItem(at: partFileURL)
			}
			if partLength == 0 {
				break
			}
			let digest = "sha=\(Data(partHash.finalize()).base64EncodedString())"
			let partProgress = progress?.makeExplicitChild(pendingUnitCount: partLength)
			let part = try await client.uploadPart(url: uploadPartURL, from: partFileURL, range: offset ... offset + partLength - 1, fileSize: localFile.size, digest: digest, progress: partProgress)
			parts.append(part)
			offset += partLength
		}
		let digest = "sha=\(Data(fileHash.finalize()).base64EncodedString())"
		try Task.checkCancellation()
		// The commit creates the file, so it runs to its end, with its retries, even if the task is cancelled meanwhile.
		let committedFiles = try await withoutCancellation { [parts] in
			try await self.client.commit(url: commitURL, parts: parts, digest: digest)
		}
		return try uploadedFile(in: committedFiles)
	}

	private func createFolder(_ creation: Preflight.CreateFolder, with name: String) async throws {
		let parentItem = creation.parent
		try await perform("createFolder(for: \(parentItem.identifier), with: \(name))") {
			let folder = try await withoutCancellation {
				try await self.client.createFolder(name: name, parentID: parentItem.identifier)
			}
			try identifierCache.commitMutation(BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), entry: folder), ifStillBelow: parentItem, unchangedSince: creation.changeMark)
		}
	}

	private func deleteFile(for item: BoxItem) async throws {
		try await perform("deleteFile(for: \(item.identifier))") {
			try await preflight.commitDelete(item) {
				try await withoutCancellation {
					try await self.client.deleteFile(id: item.identifier)
				}
			}
		}
	}

	private func deleteFolder(for item: BoxItem) async throws {
		try await perform("deleteFolder(for: \(item.identifier))") {
			try await preflight.commitDelete(item) {
				try await withoutCancellation {
					try await self.client.deleteFolder(id: item.identifier)
				}
			}
		}
	}

	private func moveFile(_ move: Preflight.Move, to targetCloudPath: CloudPath) async throws {
		let sourceItem = move.source
		let targetParentItem = move.targetParent
		try await perform("moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path))") {
			try await preflight.commitMove(move, to: targetCloudPath) {
				let file = try await withoutCancellation {
					try await self.client.moveFile(id: sourceItem.identifier, name: targetCloudPath.lastPathComponent, parentID: targetParentItem.identifier)
				}
				return try BoxItem(cloudPath: targetCloudPath, entry: file)
			}
		}
	}

	private func moveFolder(_ move: Preflight.Move, to targetCloudPath: CloudPath) async throws {
		let sourceItem = move.source
		let targetParentItem = move.targetParent
		try await perform("moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path))") {
			try await preflight.commitMove(move, to: targetCloudPath) {
				let folder = try await withoutCancellation {
					try await self.client.moveFolder(id: sourceItem.identifier, name: targetCloudPath.lastPathComponent, parentID: targetParentItem.identifier)
				}
				return try BoxItem(cloudPath: targetCloudPath, entry: folder)
			}
		}
	}

	// MARK: - Resolve Path

	private var preflight: Preflight {
		return Preflight(cache: identifierCache, providerName: "BoxCloudProvider", lookUp: getBoxItem(for:withParentItem:))
	}

	private func resolvePath(forItemAt cloudPath: CloudPath) async throws -> BoxItem {
		return try await preflight.resolve(at: cloudPath)
	}

	/// Returns the item of the name in the folder, or `nil` if the folder holds none.
	func getBoxItem(for name: String, withParentItem parentItem: BoxItem) async throws -> BoxItem? {
		return try await perform("getBoxItem(for: \(name), withParentItem: \(parentItem.identifier))") {
			try await findBoxItem(in: parentItem, withName: name, marker: nil)
		}
	}

	func findBoxItem(in parentItem: BoxItem, withName name: String, marker: String?) async throws -> BoxItem? {
		let items = try await client.folderItems(id: parentItem.identifier, marker: marker, limit: maxPageSize)
		if let foundItem = try locateBoxItem(in: items, withName: name, parentItem: parentItem) {
			return foundItem
		} else if let nextMarker = items.nextMarker {
			try Task.checkCancellation()
			return try await findBoxItem(in: parentItem, withName: name, marker: nextMarker)
		} else {
			return nil
		}
	}

	/// Returns the cached file if Box confirms that it is a live file of its name in the folder, or `nil` if it is gone or elsewhere, so that the upload looks the name up instead.
	private func confirmCachedFile(_ cachedItem: BoxItem, in parentItem: BoxItem) async throws -> BoxItem? {
		let entry: BoxEntry
		do {
			entry = try await perform("confirmCachedFile(\(cachedItem.identifier), in: \(parentItem.identifier))") {
				try await client.file(id: cachedItem.identifier, fields: BoxCloudProvider.confirmationFields)
			}
		} catch CloudProviderError.itemNotFound {
			return nil
		}
		guard entry.itemType == .file, entry.itemStatus == "active", Self.isEntry(entry, at: cachedItem.cloudPath, in: parentItem) else {
			return nil
		}
		return cachedItem
	}

	/// Skips web links, which can have the name of a file or folder but aren't cloud items.
	func locateBoxItem(in items: BoxItems, withName name: String, parentItem: BoxItem) throws -> BoxItem? {
		guard let entry = items.entries?.first(where: { $0.itemType != nil && $0.name == name }) else {
			return nil
		}
		return try BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), entry: entry)
	}

	// MARK: - Helpers

	/**
	 Converts a file or folder entry. A folder has no size or date, and a file entry without a date has none either.

	 - Parameter name: The name to report instead of the entry's.
	 - Throws: `BoxError.unexpectedContent` for any other entry, e.g., a web link, and for a file whose `modified_at` doesn't parse.
	 */
	private func convertToCloudItemMetadata(_ entry: BoxEntry, at cloudPath: CloudPath, name: String? = nil) throws -> CloudItemMetadata {
		let name = name ?? entry.name ?? ""
		switch entry.itemType {
		case .file:
			var lastModifiedDate: Date?
			if let modifiedAt = entry.modifiedAt {
				guard let date = BoxJSON.date(fromBoxDateTime: modifiedAt) else {
					throw BoxError.unexpectedContent
				}
				lastModifiedDate = date
			}
			return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: .file, lastModifiedDate: lastModifiedDate, size: entry.size.map { Int($0) })
		case .folder:
			return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: .folder, lastModifiedDate: nil, size: nil)
		default:
			throw BoxError.unexpectedContent
		}
	}

	private func uploadedFile(in files: BoxFiles) throws -> BoxEntry {
		guard let file = files.entries?.first else {
			throw CloudProviderError.itemNotFound
		}
		return file
	}

	private func convertToCloudItemList(_ folderItems: BoxItems, at cloudPath: CloudPath) throws -> CloudItemList {
		guard let entries = folderItems.entries else {
			return CloudItemList(items: [])
		}
		let items = try entries.compactMap { entry -> CloudItemMetadata? in
			let name = entry.name ?? ""
			guard name.isSinglePathComponent else {
				CloudAccessDDLogDebug("BoxCloudProvider: skipping item \(name) in \(cloudPath.path), because its name is no single path component")
				return nil
			}
			return try convertToCloudItemMetadata(entry, at: cloudPath.appendingPathComponent(name))
		}
		return CloudItemList(items: items, nextPageToken: folderItems.nextMarker)
	}

	/// Logs the operation and converts the errors that it throws.
	private func perform<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
		try await performLogged(operation, by: "BoxCloudProvider", convert: Self.convertStandardError, body)
	}

	static func convertStandardError(_ error: Error) -> Error {
		switch error {
		case BoxError.apiError(statusCode: 403, code: "storage_limit_exceeded", _):
			return CloudProviderError.quotaInsufficient
		case BoxError.apiError(statusCode: 401, _, _), BoxError.apiError(statusCode: 403, code: "insufficient_scope", _):
			// Box's other 403 codes (e.g. `access_denied_insufficient_permissions`, `access_denied_item_locked`, `forbidden_by_policy`, `access_from_location_blocked`) concern an item, a policy or the account's state, which signing in again can't fix.
			return CloudProviderError.unauthorized
		case BoxError.apiError(statusCode: 404, _, _):
			return CloudProviderError.itemNotFound
		default:
			return error
		}
	}
}
