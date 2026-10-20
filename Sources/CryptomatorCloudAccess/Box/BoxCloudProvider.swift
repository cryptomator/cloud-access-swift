//
//  BoxCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import Foundation

public final class BoxCloudProvider: CloudProvider {
	private let client: BoxClient
	private let identifierCache: BoxIdentifierCache
	private let maxPageSize: Int
	/// Box recommends uploading files of 50 MiB or more with a chunked upload.
	private let chunkedUploadThreshold: Int

	init(client: BoxClient, maxPageSize: Int, chunkedUploadThreshold: Int = 52_428_800) throws {
		self.client = client
		self.identifierCache = try BoxIdentifierCache()
		self.maxPageSize = max(1, min(maxPageSize, 1000))
		self.chunkedUploadThreshold = chunkedUploadThreshold
	}

	public convenience init(credential: BoxCredential, maxPageSize: Int = .max) throws {
		try self.init(client: .foreground(tokenSource: credential.tokenSource), maxPageSize: maxPageSize)
	}

	/**
	 Creates a Box provider whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.

	 If the provider is used in an app extension, set `BoxSetup.constants.sharedContainerIdentifier` to a valid identifier for a container that will be shared between the app and the extension.
	 */
	public static func withBackgroundSession(credential: BoxCredential, maxPageSize: Int = .max, sessionIdentifier: String) throws -> BoxCloudProvider {
		return try BoxCloudProvider(client: .background(tokenSource: credential.tokenSource, sessionIdentifier: sessionIdentifier), maxPageSize: maxPageSize)
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
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		try await deleteFile(for: item)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		try await deleteFolder(for: item)
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		if try await checkForItemExistence(at: targetCloudPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let item = try await resolvePath(forItemAt: sourceCloudPath)
		let targetParentItem = try await resolveParentPath(forItemAt: targetCloudPath)
		try Task.checkCancellation()
		try await moveFile(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		if try await checkForItemExistence(at: targetCloudPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let item = try await resolvePath(forItemAt: sourceCloudPath)
		let targetParentItem = try await resolveParentPath(forItemAt: targetCloudPath)
		try Task.checkCancellation()
		try await moveFolder(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: BoxItem) async throws -> CloudItemMetadata {
		if item.itemType == .file {
			return try await fetchFileMetadata(for: item)
		} else if item.itemType == .folder {
			return try await fetchFolderMetadata(for: item)
		} else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("BoxCloudProvider: fetchItemMetadata(for: \(item.identifier)) failed with error: \(error)")
			throw error
		}
	}

	private func fetchFileMetadata(for item: BoxItem) async throws -> CloudItemMetadata {
		assert(item.itemType == .file)
		CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item)) called")
		do {
			let file = try await client.file(id: item.identifier)
			CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) received file: \(file)")
			return try convertToCloudItemMetadata(file, at: item.cloudPath)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) error: \(error)")
			throw convertStandardError(error)
		}
	}

	private func fetchFolderMetadata(for item: BoxItem) async throws -> CloudItemMetadata {
		assert(item.itemType == .folder)
		CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) called")
		do {
			let folder = try await client.folder(id: item.identifier)
			CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) received folder: \(folder)")
			return try convertToCloudItemMetadata(folder, at: item.cloudPath)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) error: \(error)")
			throw convertStandardError(error)
		}
	}

	private func fetchItemList(for folderItem: BoxItem, pageToken: String?) async throws -> CloudItemList {
		guard folderItem.itemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
		do {
			let items = try await client.folderItems(id: folderItem.identifier, marker: pageToken, limit: maxPageSize)
			CloudAccessDDLogDebug("BoxCloudProvider: fetchItemList(for: \(folderItem.identifier), pageToken: \(pageToken ?? "nil")) received items: \(items)")
			return try convertToCloudItemList(items, at: folderItem.cloudPath)
		} catch BoxError.apiError(statusCode: 400, _, _) {
			throw CloudProviderError.pageTokenInvalid
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: fetchItemList(for: \(folderItem.identifier), pageToken: \(pageToken ?? "nil")) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	private func downloadFile(for item: BoxItem, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) called")
		guard item.itemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		let remoteMetadata = try await fetchFileMetadata(for: item)
		try Task.checkCancellation()
		return try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			do {
				try await client.download(fileID: item.identifier, to: stagedFile, progress: progress, onTaskCreation: onTaskCreation)
				CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) finished")
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) failed with error: \(error)")
				throw convertStandardError(error)
			}
			return remoteMetadata
		})
	}

	// swiftlint:disable:next function_parameter_count
	private func uploadFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("BoxCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath), replaceExisting: \(replaceExisting)) called")
		let attributes: [FileAttributeKey: Any]
		do {
			attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
		} catch CocoaError.fileReadNoSuchFile {
			throw CloudProviderError.itemNotFound
		}
		let fileSize = attributes[FileAttributeKey.size] as? Int ?? chunkedUploadThreshold
		do {
			let item = try await resolvePath(forItemAt: cloudPath)
			if !replaceExisting || (replaceExisting && item.itemType == .folder) {
				throw CloudProviderError.itemAlreadyExists
			}
			try Task.checkCancellation()
			if fileSize >= chunkedUploadThreshold {
				return try await uploadLargeExistingFile(for: item, from: localURL, to: cloudPath, fileSize: fileSize, progress: progress)
			} else {
				return try await uploadSmallExistingFile(for: item, from: localURL, to: cloudPath, progress: progress, onTaskCreation: onTaskCreation)
			}
		} catch CloudProviderError.itemNotFound {
			try Task.checkCancellation()
			if fileSize >= chunkedUploadThreshold {
				return try await uploadLargeNewFile(for: parentItem, from: localURL, to: cloudPath, fileSize: fileSize, progress: progress)
			} else {
				return try await uploadSmallNewFile(for: parentItem, from: localURL, to: cloudPath, progress: progress, onTaskCreation: onTaskCreation)
			}
		}
	}

	private func uploadSmallNewFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		do {
			let files = try await client.uploadNewFile(from: localURL, name: cloudPath.lastPathComponent, parentID: parentItem.identifier, progress: progress, onTaskCreation: onTaskCreation)
			guard let file = files.entries?.first else {
				throw CloudProviderError.itemNotFound
			}
			CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallNewFile(for: \(parentItem.identifier), to: \(cloudPath)) received file: \(file)")
			return try convertToCloudItemMetadata(file, at: cloudPath)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallNewFile(for: \(parentItem.identifier), to: \(cloudPath)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	private func uploadSmallExistingFile(for existingItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		do {
			let files = try await client.uploadFileVersion(from: localURL, fileID: existingItem.identifier, name: cloudPath.lastPathComponent, progress: progress, onTaskCreation: onTaskCreation)
			guard let file = files.entries?.first else {
				throw CloudProviderError.itemNotFound
			}
			CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallExistingFile(for: \(existingItem.identifier), to: \(cloudPath)) received file: \(file)")
			return try convertToCloudItemMetadata(file, at: cloudPath)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallExistingFile(for: \(existingItem.identifier), to: \(cloudPath)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	private func uploadLargeNewFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, fileSize: Int, progress: Progress?) async throws -> CloudItemMetadata {
		do {
			let uploadSession = try await client.createUploadSession(parentID: parentItem.identifier, name: cloudPath.lastPathComponent, fileSize: Int64(fileSize))
			return try await uploadLargeFile(for: uploadSession, from: localURL, to: cloudPath, fileSize: fileSize, progress: progress)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: uploadLargeNewFile(for: \(parentItem.identifier), to: \(cloudPath), fileSize: \(fileSize)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	private func uploadLargeExistingFile(for existingItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, fileSize: Int, progress: Progress?) async throws -> CloudItemMetadata {
		do {
			let uploadSession = try await client.createUploadSession(fileID: existingItem.identifier, fileSize: Int64(fileSize))
			return try await uploadLargeFile(for: uploadSession, from: localURL, to: cloudPath, fileSize: fileSize, progress: progress)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: uploadLargeExistingFile(for: \(existingItem.identifier), to: \(cloudPath), fileSize: \(fileSize)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	/// Uploads the parts one by one, each from a temporary file, so that no part is held in memory. The progress counts bytes, and each part gets a share of its length.
	private func uploadLargeFile(for uploadSession: BoxUploadSession, from localURL: URL, to cloudPath: CloudPath, fileSize: Int, progress: Progress?) async throws -> CloudItemMetadata {
		guard let uploadPartURL = uploadSession.sessionEndpoints?.uploadPart, let commitURL = uploadSession.sessionEndpoints?.commit, let partSize = uploadSession.partSize, partSize > 0 else {
			throw BoxError.unexpectedContent
		}
		progress?.totalUnitCount = Int64(fileSize)
		var fileHash = Insecure.SHA1()
		var parts = [BoxPart]()
		var offset: Int64 = 0
		let fileHandle = try FileHandle(forReadingFrom: localURL)
		defer {
			try? fileHandle.close()
		}
		while true {
			try Task.checkCancellation()
			var partHash = Insecure.SHA1()
			var partLength: Int64 = 0
			let partFileURL = try BoxClient.writeTemporaryFile { partHandle in
				while partLength < partSize, let chunk = try fileHandle.read(upToCount: Int(min(Int64(BoxClient.bufferLength), partSize - partLength))), !chunk.isEmpty {
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
			let part = try await client.uploadPart(url: uploadPartURL, from: partFileURL, range: offset ... offset + partLength - 1, fileSize: Int64(fileSize), digest: digest, progress: partProgress)
			parts.append(part)
			offset += partLength
		}
		let digest = "sha=\(Data(fileHash.finalize()).base64EncodedString())"
		try Task.checkCancellation()
		// The commit creates the file, so it runs to its end, with its retries, even if the task is cancelled meanwhile.
		let committedFiles = try await withoutCancellation { [parts] in
			try await self.client.commit(url: commitURL, parts: parts, digest: digest)
		}
		guard let file = committedFiles.entries?.first else {
			throw CloudProviderError.itemNotFound
		}
		CloudAccessDDLogDebug("BoxCloudProvider: uploadLargeFile(to: \(cloudPath), fileSize: \(fileSize)) received file: \(file)")
		return try convertToCloudItemMetadata(file, at: cloudPath)
	}

	private func createFolder(for parentItem: BoxItem, with name: String) async throws {
		do {
			let folder = try await withoutCancellation {
				try await self.client.createFolder(name: name, parentID: parentItem.identifier)
			}
			CloudAccessDDLogDebug("BoxCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) received folder: \(folder)")
			let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
			let item = try BoxItem(cloudPath: cloudPath, entry: folder)
			try identifierCache.addOrUpdate(item)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	private func deleteFile(for item: BoxItem) async throws {
		CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) called")
		guard item.itemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		do {
			try await withoutCancellation {
				try await self.client.deleteFile(id: item.identifier)
			}
			CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) succeeded")
			try identifierCache.invalidate(item)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	private func deleteFolder(for item: BoxItem) async throws {
		CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) called")
		guard item.itemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
		do {
			try await withoutCancellation {
				try await self.client.deleteFolder(id: item.identifier)
			}
			CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) succeeded")
			try identifierCache.invalidate(item)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	private func moveFile(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) async throws {
		CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		do {
			let file = try await withoutCancellation {
				try await self.client.moveFile(id: sourceItem.identifier, name: targetCloudPath.lastPathComponent, parentID: targetParentItem.identifier)
			}
			CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received file: \(file)")
			try identifierCache.invalidate(sourceItem)
			let targetItem = try BoxItem(cloudPath: targetCloudPath, entry: file)
			try identifierCache.addOrUpdate(targetItem)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	private func moveFolder(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) async throws {
		CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		do {
			let folder = try await withoutCancellation {
				try await self.client.moveFolder(id: sourceItem.identifier, name: targetCloudPath.lastPathComponent, parentID: targetParentItem.identifier)
			}
			CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received folder: \(folder)")
			try identifierCache.invalidate(sourceItem)
			let newItem = try BoxItem(cloudPath: targetCloudPath, entry: folder)
			try identifierCache.addOrUpdate(newItem)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	// MARK: - Resolve Path

	private func resolvePath(forItemAt cloudPath: CloudPath) async throws -> BoxItem {
		var pathToCheckForCache = cloudPath
		var cachedItem = identifierCache.get(pathToCheckForCache)
		while cachedItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
			pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
			cachedItem = identifierCache.get(pathToCheckForCache)
		}
		guard let item = cachedItem else {
			throw BoxError.inconsistentCache
		}
		if pathToCheckForCache != cloudPath {
			return try await traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: item)
		}
		return item
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) async throws -> BoxItem {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		do {
			return try await resolvePath(forItemAt: parentCloudPath)
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}

	private func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: BoxItem) async throws -> BoxItem {
		assert(startCloudPath.pathComponents.count < endCloudPath.pathComponents.count)
		let startIndex = startCloudPath.pathComponents.count
		let endIndex = endCloudPath.pathComponents.count
		var parentItem = startItem
		for i in startIndex ..< endIndex {
			let itemName = endCloudPath.pathComponents[i]
			try Task.checkCancellation()
			parentItem = try await getBoxItem(for: itemName, withParentItem: parentItem)
			try identifierCache.addOrUpdate(parentItem)
		}
		return parentItem
	}

	func getBoxItem(for name: String, withParentItem parentItem: BoxItem) async throws -> BoxItem {
		do {
			let foundItem = try await findBoxItem(in: parentItem, withName: name, marker: nil)
			CloudAccessDDLogDebug("BoxCloudProvider: getBoxItem(for: \(name), withParentItem: \(parentItem.identifier)) found item: \(foundItem)")
			return foundItem
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: getBoxItem(for: \(name), withParentItem: \(parentItem.identifier)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	func findBoxItem(in parentItem: BoxItem, withName name: String, marker: String?) async throws -> BoxItem {
		let items = try await client.folderItems(id: parentItem.identifier, marker: marker, limit: maxPageSize)
		CloudAccessDDLogDebug("BoxCloudProvider: findBoxItem(in: \(parentItem.identifier), withName: \(name), marker: \(marker ?? "nil")) received items: \(items)")
		if let foundItem = try locateBoxItem(in: items, withName: name, parentItem: parentItem) {
			return foundItem
		} else if let nextMarker = items.nextMarker {
			try Task.checkCancellation()
			return try await findBoxItem(in: parentItem, withName: name, marker: nextMarker)
		} else {
			throw CloudProviderError.itemNotFound
		}
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

	 - Throws: `BoxError.unexpectedContent` for any other entry, e.g., a web link, and for a file whose `modified_at` doesn't parse.
	 */
	private func convertToCloudItemMetadata(_ entry: BoxEntry, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		let name = entry.name ?? ""
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

	private func convertToCloudItemList(_ folderItems: BoxItems, at cloudPath: CloudPath) throws -> CloudItemList {
		guard let entries = folderItems.entries else {
			return CloudItemList(items: [])
		}
		let items = try entries.map { entry in
			try convertToCloudItemMetadata(entry, at: cloudPath.appendingPathComponent(entry.name ?? ""))
		}
		return CloudItemList(items: items, nextPageToken: folderItems.nextMarker)
	}

	func convertStandardError(_ error: Error) -> Error {
		switch error {
		case BoxError.apiError(statusCode: 401, _, _), BoxError.apiError(statusCode: 403, _, _):
			return CloudProviderError.unauthorized
		case BoxError.apiError(statusCode: 404, _, _):
			return CloudProviderError.itemNotFound
		default:
			return error
		}
	}
}
