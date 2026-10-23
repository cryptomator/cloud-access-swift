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
		return try await perform("fetchFileMetadata(for: \(item.identifier))") {
			try await convertToCloudItemMetadata(client.file(id: item.identifier), at: item.cloudPath)
		}
	}

	private func fetchFolderMetadata(for item: BoxItem) async throws -> CloudItemMetadata {
		assert(item.itemType == .folder)
		return try await perform("fetchFolderMetadata(for: \(item.identifier))") {
			try await convertToCloudItemMetadata(client.folder(id: item.identifier), at: item.cloudPath)
		}
	}

	private func fetchItemList(for folderItem: BoxItem, pageToken: String?) async throws -> CloudItemList {
		guard folderItem.itemType == .folder else {
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
		guard item.itemType == .file else {
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
		return try await perform("uploadSmallNewFile(for: \(parentItem.identifier), to: \(cloudPath))") {
			let files = try await client.uploadNewFile(from: localURL, name: cloudPath.lastPathComponent, parentID: parentItem.identifier, progress: progress, onTaskCreation: onTaskCreation)
			return try convertToUploadedFileMetadata(files, at: cloudPath)
		}
	}

	private func uploadSmallExistingFile(for existingItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		return try await perform("uploadSmallExistingFile(for: \(existingItem.identifier), to: \(cloudPath))") {
			let files = try await client.uploadFileVersion(from: localURL, fileID: existingItem.identifier, name: cloudPath.lastPathComponent, progress: progress, onTaskCreation: onTaskCreation)
			return try convertToUploadedFileMetadata(files, at: cloudPath)
		}
	}

	private func uploadLargeNewFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, fileSize: Int, progress: Progress?) async throws -> CloudItemMetadata {
		return try await perform("uploadLargeNewFile(for: \(parentItem.identifier), to: \(cloudPath), fileSize: \(fileSize))") {
			let uploadSession = try await client.createUploadSession(parentID: parentItem.identifier, name: cloudPath.lastPathComponent, fileSize: Int64(fileSize))
			return try await uploadLargeFile(for: uploadSession, from: localURL, to: cloudPath, fileSize: fileSize, progress: progress)
		}
	}

	private func uploadLargeExistingFile(for existingItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, fileSize: Int, progress: Progress?) async throws -> CloudItemMetadata {
		return try await perform("uploadLargeExistingFile(for: \(existingItem.identifier), to: \(cloudPath), fileSize: \(fileSize))") {
			let uploadSession = try await client.createUploadSession(fileID: existingItem.identifier, fileSize: Int64(fileSize))
			return try await uploadLargeFile(for: uploadSession, from: localURL, to: cloudPath, fileSize: fileSize, progress: progress)
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
		return try convertToUploadedFileMetadata(committedFiles, at: cloudPath)
	}

	private func createFolder(for parentItem: BoxItem, with name: String) async throws {
		try await perform("createFolder(for: \(parentItem.identifier), with: \(name))") {
			let folder = try await withoutCancellation {
				try await self.client.createFolder(name: name, parentID: parentItem.identifier)
			}
			try identifierCache.addOrUpdate(BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), entry: folder))
		}
	}

	private func deleteFile(for item: BoxItem) async throws {
		guard item.itemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		try await perform("deleteFile(for: \(item.identifier))") {
			try await withoutCancellation {
				try await self.client.deleteFile(id: item.identifier)
			}
			try identifierCache.invalidate(item)
		}
	}

	private func deleteFolder(for item: BoxItem) async throws {
		guard item.itemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
		try await perform("deleteFolder(for: \(item.identifier))") {
			try await withoutCancellation {
				try await self.client.deleteFolder(id: item.identifier)
			}
			try identifierCache.invalidate(item)
		}
	}

	private func moveFile(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) async throws {
		try await perform("moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path))") {
			let file = try await withoutCancellation {
				try await self.client.moveFile(id: sourceItem.identifier, name: targetCloudPath.lastPathComponent, parentID: targetParentItem.identifier)
			}
			try identifierCache.invalidate(sourceItem)
			try identifierCache.addOrUpdate(BoxItem(cloudPath: targetCloudPath, entry: file))
		}
	}

	private func moveFolder(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) async throws {
		try await perform("moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path))") {
			let folder = try await withoutCancellation {
				try await self.client.moveFolder(id: sourceItem.identifier, name: targetCloudPath.lastPathComponent, parentID: targetParentItem.identifier)
			}
			try identifierCache.invalidate(sourceItem)
			try identifierCache.addOrUpdate(BoxItem(cloudPath: targetCloudPath, entry: folder))
		}
	}

	// MARK: - Resolve Path

	private func resolvePath(forItemAt cloudPath: CloudPath) async throws -> BoxItem {
		return try await identifierCache.resolvePath(forItemAt: cloudPath, lookUpChild: getBoxItem(for:withParentItem:))
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) async throws -> BoxItem {
		return try await identifierCache.resolveParentPath(forItemAt: cloudPath, lookUpChild: getBoxItem(for:withParentItem:))
	}

	func getBoxItem(for name: String, withParentItem parentItem: BoxItem) async throws -> BoxItem {
		return try await perform("getBoxItem(for: \(name), withParentItem: \(parentItem.identifier))") {
			try await findBoxItem(in: parentItem, withName: name, marker: nil)
		}
	}

	func findBoxItem(in parentItem: BoxItem, withName name: String, marker: String?) async throws -> BoxItem {
		let items = try await client.folderItems(id: parentItem.identifier, marker: marker, limit: maxPageSize)
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

	private func convertToUploadedFileMetadata(_ files: BoxFiles, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		guard let file = files.entries?.first else {
			throw CloudProviderError.itemNotFound
		}
		return try convertToCloudItemMetadata(file, at: cloudPath)
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

	/// Logs the operation and converts the errors that it throws.
	private func perform<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
		CloudAccessDDLogDebug("BoxCloudProvider: \(operation) called")
		do {
			return try await body()
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: \(operation) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	func convertStandardError(_ error: Error) -> Error {
		switch error {
		case BoxError.apiError(statusCode: 403, code: "storage_limit_exceeded", _):
			return CloudProviderError.quotaInsufficient
		case BoxError.apiError(statusCode: 401, _, _), BoxError.apiError(statusCode: 403, _, _):
			return CloudProviderError.unauthorized
		case BoxError.apiError(statusCode: 404, _, _):
			return CloudProviderError.itemNotFound
		default:
			return error
		}
	}
}
