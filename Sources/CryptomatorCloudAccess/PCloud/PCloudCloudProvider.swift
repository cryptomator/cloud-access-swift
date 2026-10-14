//
//  PCloudCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 16.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import PCloudSDKSwift

/// Safe to share across threads, because `PCloudClient` only builds tasks from its immutable task builders and every task guards its own state.
public final class PCloudCloudProvider: CloudProvider {
	private let client: PCloudClient
	private let identifierCache: PCloudIdentifierCache

	public init(client: PCloudClient) throws {
		self.client = client
		self.identifierCache = try PCloudIdentifierCache()
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
		guard pageToken == nil else {
			throw CloudProviderError.pageTokenInvalid
		}
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		return try await fetchItemList(for: item)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let phases = Progress.phases(of: progress, 999)
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		let metadata = try await downloadFile(for: item, to: localURL, progress: phases[0])
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
		try Task.checkCancellation()
		do {
			let targetName = cloudPath.lastPathComponent
			let metadata = try await client.listFolder(parentItem.identifier, recursively: false).execute()
			let existingContent = metadata.contents.first(where: { $0.fileMetadata?.name == targetName || $0.folderMetadata?.name == targetName })
			if let existingContent {
				if !replaceExisting || existingContent.folderMetadata != nil {
					throw CloudProviderError.itemAlreadyExists
				}
			}
		} catch {
			guard let error = error as? CallError<PCloudAPI.ListFolder.Error> else {
				throw error
			}
			if case CallError.methodError(.folderDoesNotExist) = error {
				throw CloudProviderError.parentFolderDoesNotExist
			} else {
				throw error
			}
		}
		try Task.checkCancellation()
		let metadata = try await uploadFile(for: parentItem, from: localURL, to: cloudPath, progress: phases[0])
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let parentItem = try await resolveParentPath(forItemAt: cloudPath)
		try Task.checkCancellation()
		try await checkForNameCollision(cloudPath.lastPathComponent, inFolder: parentItem)
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
		let (sourceItem, targetParentItem) = try await resolveForMove(from: sourceCloudPath, to: targetCloudPath)
		try Task.checkCancellation()
		try await moveFile(from: sourceItem, toParent: targetParentItem, targetCloudPath: targetCloudPath)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let (sourceItem, targetParentItem) = try await resolveForMove(from: sourceCloudPath, to: targetCloudPath)
		try Task.checkCancellation()
		try await moveFolder(from: sourceItem, toParent: targetParentItem, targetCloudPath: targetCloudPath)
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: PCloudItem) async throws -> CloudItemMetadata {
		if item.itemType == .file {
			return try await fetchFileMetadata(for: item)
		} else if item.itemType == .folder {
			return try await fetchFolderMetadata(for: item)
		} else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemMetadata(for: \(item.identifier)) failed with error: \(error)")
			throw error
		}
	}

	private func fetchFileMetadata(for item: PCloudItem) async throws -> CloudItemMetadata {
		assert(item.itemType == .file)
		CloudAccessDDLogDebug("PCloudCloudProvider: fetchFileMetadata(for: \(item.identifier)) called")
		do {
			let metadata = try await client.getFileMetadata(item.identifier).execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchFileMetadata(for: \(item.identifier)) received metadata: \(metadata)")
			try identifierCache.addOrUpdate(item)
			return convertToCloudItemMetadata(metadata, at: item.cloudPath)
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchFileMetadata(for: \(item.identifier)) failed with error: \(error)")
			guard let error = error as? CallError<PCloudAPI.Stat.Error> else {
				throw error
			}
			if case CallError.methodError(.fileDoesNotExist) = error {
				throw CloudProviderError.itemNotFound
			} else {
				throw error
			}
		}
	}

	private func fetchFolderMetadata(for item: PCloudItem) async throws -> CloudItemMetadata {
		assert(item.itemType == .folder)
		CloudAccessDDLogDebug("PCloudCloudProvider: fetchFolderMetadata(for: \(item.identifier)) called")
		do {
			let metadata = try await client.listFolder(item.identifier, recursively: false).execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchFolderMetadata(for: \(item.identifier)) received metadata: \(metadata)")
			try identifierCache.addOrUpdate(item)
			return convertToCloudItemMetadata(metadata, at: item.cloudPath)
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchFolderMetadata(for: \(item.identifier)) failed with error: \(error)")
			guard let error = error as? CallError<PCloudAPI.ListFolder.Error> else {
				throw error
			}
			if case CallError.methodError(.folderDoesNotExist) = error {
				throw CloudProviderError.itemNotFound
			} else {
				throw error
			}
		}
	}

	private func fetchItemList(for item: PCloudItem) async throws -> CloudItemList {
		CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemList(for: \(item.identifier)) called")
		guard item.itemType == .folder else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemList(for: \(item.identifier)) failed with error: \(error)")
			throw error
		}
		do {
			let metadata = try await client.listFolder(item.identifier, recursively: false).execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemList(for: \(item.identifier)) received metadata: \(metadata)")
			for content in metadata.contents {
				guard let name = content.fileMetadata?.name ?? content.folderMetadata?.name else {
					continue
				}
				let childCloudPath = item.cloudPath.appendingPathComponent(name)
				let childItem = try PCloudItem(cloudPath: childCloudPath, content: content)
				try identifierCache.addOrUpdate(childItem)
			}
			return try convertToCloudItemList(metadata.contents, at: item.cloudPath)
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemList(for: \(item.identifier)) failed with error: \(error)")
			guard let error = error as? CallError<PCloudAPI.ListFolder.Error> else {
				throw error
			}
			if case CallError.methodError(.folderDoesNotExist) = error {
				throw CloudProviderError.itemNotFound
			} else {
				throw error
			}
		}
	}

	private func downloadFile(for item: PCloudItem, to localURL: URL, progress: Progress?) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("PCloudCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) called")
		guard item.itemType == .file else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("PCloudCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) failed with error: \(error)")
			throw error
		}
		let remoteMetadata = try await fetchFileMetadata(for: item)
		try Task.checkCancellation()
		let fileLink = try await getFileLink(for: item)
		try Task.checkCancellation()
		let metadata = try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			try await downloadFileLink(fileLink, to: stagedFile, progress: progress)
			return remoteMetadata
		})
		CloudAccessDDLogDebug("PCloudCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) finished")
		return metadata
	}

	private func getFileLink(for item: PCloudItem) async throws -> FileLink.Metadata {
		assert(item.itemType == .file)
		CloudAccessDDLogDebug("PCloudCloudProvider: getFileLink(for: \(item.identifier)) called")
		do {
			let metadata = try await client.getFileLink(forFile: item.identifier).execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: getFileLink(for: \(item.identifier)) received metadata: \(metadata)")
			if let first = metadata.first {
				return first
			} else {
				throw PCloudError.fileLinkNotFound
			}
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: getFileLink(for: \(item.identifier)) failed with error: \(error)")
			guard let error = error as? CallError<PCloudAPI.GetFileLink.Error> else {
				throw error
			}
			if case CallError.methodError(.fileDoesNotExist) = error {
				throw CloudProviderError.itemNotFound
			} else {
				throw error
			}
		}
	}

	private func downloadFileLink(_ fileLink: FileLink.Metadata, to localURL: URL, progress: Progress?) async throws {
		CloudAccessDDLogDebug("PCloudCloudProvider: downloadFileLink(\(fileLink), to: \(localURL)) called")
		let task = client.downloadFile(from: fileLink.address, downloadTag: fileLink.downloadTag, to: { tmpURL in
			try FileManager.default.moveItem(at: tmpURL, to: localURL)
			return localURL
		})
		task.addProgressBlock { numberOfBytesSent, totalNumberOfBytesToSend in
			progress?.totalUnitCount = totalNumberOfBytesToSend
			progress?.completedUnitCount = numberOfBytesSent
		}
		do {
			let url = try await task.execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: downloadFileLink(\(fileLink), to: \(localURL)) finished downloading to: \(url)")
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: downloadFileLink(\(fileLink), to: \(localURL)) failed with error: \(error)")
			throw error
		}
	}

	private func uploadFile(for parentItem: PCloudItem, from localURL: URL, to cloudPath: CloudPath, progress: Progress?) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("PCloudCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path)) called")
		let task = client.upload(fromFileAt: localURL, toFolder: parentItem.identifier, asFileNamed: cloudPath.lastPathComponent)
		task.addProgressBlock { numberOfBytesSent, totalNumberOfBytesToSend in
			progress?.totalUnitCount = totalNumberOfBytesToSend
			progress?.completedUnitCount = numberOfBytesSent
		}
		do {
			let metadata = try await task.execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path)) received metadata: \(metadata)")
			let item = PCloudItem(cloudPath: cloudPath, metadata: metadata)
			try identifierCache.addOrUpdate(item)
			return convertToCloudItemMetadata(metadata, at: cloudPath)
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path)) failed with error: \(error)")
			switch error as? CallError<PCloudAPI.UploadFile.Error> {
			case .methodError(.parentFolderDoesNotExist):
				throw CloudProviderError.parentFolderDoesNotExist
			case .permissionError(.userIsOverQuota):
				throw CloudProviderError.quotaInsufficient
			default:
				throw error
			}
		}
	}

	private func createFolder(for parentItem: PCloudItem, with name: String) async throws {
		CloudAccessDDLogDebug("PCloudCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) called")
		do {
			let metadata = try await client.createFolder(named: name, inFolder: parentItem.identifier).execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) received metadata: \(metadata)")
			let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
			let item = PCloudItem(cloudPath: cloudPath, metadata: metadata)
			try identifierCache.addOrUpdate(item)
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) failed with error: \(error)")
			switch error as? CallError<PCloudAPI.CreateFolder.Error> {
			case .methodError(.componentOfParentDirectoryDoesNotExist):
				throw CloudProviderError.parentFolderDoesNotExist
			case .methodError(.folderAlreadyExists):
				throw CloudProviderError.itemAlreadyExists
			case .permissionError(.userIsOverQuota):
				throw CloudProviderError.quotaInsufficient
			default:
				throw error
			}
		}
	}

	private func deleteFile(for item: PCloudItem) async throws {
		CloudAccessDDLogDebug("PCloudCloudProvider: deleteFile(for: \(item.identifier)) called")
		do {
			let metadata = try await client.deleteFile(item.identifier).execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: deleteFile(for: \(item.identifier)) received metadata: \(metadata)")
			try identifierCache.invalidate(item)
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: deleteFile(for: \(item.identifier)) failed with error: \(error)")
			guard let error = error as? CallError<PCloudAPI.DeleteFile.Error> else {
				throw error
			}
			if case CallError.methodError(.fileDoesNotExist) = error {
				throw CloudProviderError.itemNotFound
			} else {
				throw error
			}
		}
	}

	private func deleteFolder(for item: PCloudItem) async throws {
		CloudAccessDDLogDebug("PCloudCloudProvider: deleteFolder(for: \(item.identifier)) called")
		do {
			try await client.deleteFolderRecursively(item.identifier).execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: deleteFolder(for: \(item.identifier)) finished")
			try identifierCache.invalidate(item)
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: deleteFolder(for: \(item.identifier)) failed with error: \(error)")
			guard let error = error as? CallError<PCloudAPI.DeleteFolderRecursive.Error> else {
				throw error
			}
			if case CallError.methodError(.folderDoesNotExist) = error {
				throw CloudProviderError.itemNotFound
			} else {
				throw error
			}
		}
	}

	private func moveFile(from sourceItem: PCloudItem, toParent targetParentItem: PCloudItem, targetCloudPath: CloudPath) async throws {
		CloudAccessDDLogDebug("PCloudCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		do {
			let metadata = try await client.moveFile(sourceItem.identifier, toFolder: targetParentItem.identifier, newName: targetCloudPath.lastPathComponent).execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received metadata: \(metadata)")
			try identifierCache.invalidate(sourceItem)
			let targetItem = PCloudItem(cloudPath: targetCloudPath, metadata: metadata)
			try identifierCache.addOrUpdate(targetItem)
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) failed with error: \(error)")
			switch error as? CallError<PCloudAPI.MoveFile.Error> {
			case .methodError(.folderDoesNotExist):
				throw CloudProviderError.parentFolderDoesNotExist
			case .methodError(.fileDoesNotExist):
				throw CloudProviderError.itemNotFound
			case .permissionError(.userIsOverQuota):
				throw CloudProviderError.quotaInsufficient
			default:
				throw error
			}
		}
	}

	private func moveFolder(from sourceItem: PCloudItem, toParent targetParentItem: PCloudItem, targetCloudPath: CloudPath) async throws {
		CloudAccessDDLogDebug("PCloudCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		do {
			let metadata = try await client.moveFolder(sourceItem.identifier, toFolder: targetParentItem.identifier, newName: targetCloudPath.lastPathComponent).execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received metadata: \(metadata)")
			try identifierCache.invalidate(sourceItem)
			let targetItem = PCloudItem(cloudPath: targetCloudPath, metadata: metadata)
			try identifierCache.addOrUpdate(targetItem)
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) failed with error: \(error)")
			switch error as? CallError<PCloudAPI.MoveFolder.Error> {
			case .methodError(.folderAlreadyExists):
				throw CloudProviderError.itemAlreadyExists
			case .methodError(.folderDoesNotExist):
				throw CloudProviderError.itemNotFound
			case .permissionError(.userIsOverQuota):
				throw CloudProviderError.quotaInsufficient
			default:
				throw error
			}
		}
	}

	// MARK: - Resolve Path

	private func resolvePath(forItemAt cloudPath: CloudPath) async throws -> PCloudItem {
		var pathToCheckForCache = cloudPath
		var cachedItem = identifierCache.get(pathToCheckForCache)
		while cachedItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
			pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
			cachedItem = identifierCache.get(pathToCheckForCache)
		}
		guard let item = cachedItem else {
			throw PCloudError.inconsistentCache
		}
		if pathToCheckForCache != cloudPath {
			return try await traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: item)
		}
		return item
	}

	private func resolveForMove(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws -> (PCloudItem, PCloudItem) {
		let targetParentItem = try await resolveParentPath(forItemAt: targetCloudPath)
		let sourceItem = try await resolvePath(forItemAt: sourceCloudPath)
		try Task.checkCancellation()
		try await checkForNameCollision(targetCloudPath.lastPathComponent, inFolder: targetParentItem)
		return (sourceItem, targetParentItem)
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) async throws -> PCloudItem {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		do {
			return try await resolvePath(forItemAt: parentCloudPath)
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}

	private func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: PCloudItem) async throws -> PCloudItem {
		assert(startCloudPath.pathComponents.count < endCloudPath.pathComponents.count)
		let startIndex = startCloudPath.pathComponents.count
		let endIndex = endCloudPath.pathComponents.count
		var parentItem = startItem
		for i in startIndex ..< endIndex {
			let itemName = endCloudPath.pathComponents[i]
			try Task.checkCancellation()
			parentItem = try await getPCloudItem(for: itemName, withParentItem: parentItem)
			try identifierCache.addOrUpdate(parentItem)
		}
		return parentItem
	}

	private func getPCloudItem(for name: String, withParentItem parentItem: PCloudItem) async throws -> PCloudItem {
		CloudAccessDDLogDebug("PCloudCloudProvider: getPCloudItem(for: \(name), withParentItem: \(parentItem.identifier)) called")
		do {
			let metadata = try await client.listFolder(parentItem.identifier, recursively: false).execute()
			CloudAccessDDLogDebug("PCloudCloudProvider: getPCloudItem(for: \(name), withParentItem: \(parentItem.identifier)) received metadata: \(metadata)")
			guard let content = metadata.contents.first(where: { $0.fileMetadata?.name == name || $0.folderMetadata?.name == name }) else {
				throw CloudProviderError.itemNotFound
			}
			return try PCloudItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), content: content)
		} catch {
			CloudAccessDDLogDebug("PCloudCloudProvider: getPCloudItem(for: \(name), withParentItem: \(parentItem.identifier)) failed with error: \(error)")
			guard let error = error as? CallError<PCloudAPI.ListFolder.Error> else {
				throw error
			}
			if case CallError.methodError(.folderDoesNotExist) = error {
				throw CloudProviderError.itemNotFound
			} else {
				throw error
			}
		}
	}

	// MARK: - Helpers

	private func checkForNameCollision(_ name: String, inFolder parentItem: PCloudItem) async throws {
		do {
			let metadata = try await client.listFolder(parentItem.identifier, recursively: false).execute()
			if metadata.contents.contains(where: { $0.fileMetadata?.name == name || $0.folderMetadata?.name == name }) {
				throw CloudProviderError.itemAlreadyExists
			}
		} catch {
			guard let error = error as? CallError<PCloudAPI.ListFolder.Error> else {
				throw error
			}
			if case CallError.methodError(.folderDoesNotExist) = error {
				throw CloudProviderError.parentFolderDoesNotExist
			} else {
				throw error
			}
		}
	}

	private func convertToCloudItemMetadata(_ content: Content, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		if let fileMetadata = content.fileMetadata {
			return convertToCloudItemMetadata(fileMetadata, at: cloudPath)
		} else if let folderMetadata = content.folderMetadata {
			return convertToCloudItemMetadata(folderMetadata, at: cloudPath)
		} else {
			throw PCloudError.unexpectedContent
		}
	}

	private func convertToCloudItemMetadata(_ metadata: File.Metadata, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = metadata.name
		let itemType = CloudItemType.file
		let lastModifiedDate = Date(timeIntervalSince1970: TimeInterval(metadata.modifiedTime))
		let size = Int(truncatingIfNeeded: metadata.size)
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
	}

	private func convertToCloudItemMetadata(_ metadata: Folder.Metadata, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = metadata.name
		let itemType = CloudItemType.folder
		let lastModifiedDate = Date(timeIntervalSince1970: TimeInterval(metadata.modifiedTime))
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: nil)
	}

	private func convertToCloudItemList(_ contents: [Content], at cloudPath: CloudPath) throws -> CloudItemList {
		var items = [CloudItemMetadata]()
		for content in contents {
			if let fileMetadata = content.fileMetadata {
				let name = fileMetadata.name
				let itemCloudPath = cloudPath.appendingPathComponent(name)
				let itemMetadata = convertToCloudItemMetadata(fileMetadata, at: itemCloudPath)
				items.append(itemMetadata)
			} else if let folderMetadata = content.folderMetadata {
				let name = folderMetadata.name
				let itemCloudPath = cloudPath.appendingPathComponent(name)
				let itemMetadata = convertToCloudItemMetadata(folderMetadata, at: itemCloudPath)
				items.append(itemMetadata)
			} else {
				throw PCloudError.unexpectedContent
			}
		}
		return CloudItemList(items: items, nextPageToken: nil)
	}
}
