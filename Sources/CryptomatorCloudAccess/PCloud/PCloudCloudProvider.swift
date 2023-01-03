//
//  PCloudCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 16.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import PCloudSDKSwift
import Promises

public class PCloudCloudProvider: CloudProvider {
	private let credential: PCloudCredential
	private let identifierCache: PCloudIdentifierCache

	public init(credential: PCloudCredential) throws {
		self.credential = credential
		self.identifierCache = try PCloudIdentifierCache()
	}

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		return resolvePath(forItemAt: cloudPath).then { item in
			return self.fetchItemMetadata(for: item)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		guard pageToken == nil else {
			return Promise(CloudProviderError.pageTokenInvalid)
		}
		return resolvePath(forItemAt: cloudPath).then { item in
			return self.fetchItemList(for: item)
		}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<Void> {
		precondition(localURL.isFileURL)
		if FileManager.default.fileExists(atPath: localURL.path) {
			return Promise(CloudProviderError.itemAlreadyExists)
		}
		return resolvePath(forItemAt: cloudPath).then { item in
			self.downloadFile(for: item, to: localURL)
		}
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		var isDirectory: ObjCBool = false
		let fileExists = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
		if !fileExists {
			return Promise(CloudProviderError.itemNotFound)
		}
		if isDirectory.boolValue {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		return fetchItemMetadata(at: cloudPath).then { metadata -> Void in
			if !replaceExisting || (replaceExisting && metadata.itemType == .folder) {
				throw CloudProviderError.itemAlreadyExists
			}
		}.recover { error -> Void in
			guard case CloudProviderError.itemNotFound = error else {
				throw error
			}
		}.then { _ -> Promise<PCloudItem> in
			return self.resolveParentPath(forItemAt: cloudPath)
		}.then { parentItem in
			return self.uploadFile(for: parentItem, from: localURL, to: cloudPath)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: cloudPath).then { itemExists -> Void in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then {
			self.resolveParentPath(forItemAt: cloudPath)
		}.then { parentItem in
			return self.createFolder(for: parentItem, with: cloudPath.lastPathComponent)
		}
	}

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		return resolvePath(forItemAt: cloudPath).then { item in
			return self.deleteFile(for: item)
		}
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return resolvePath(forItemAt: cloudPath).then { item in
			return self.deleteFolder(for: item)
		}
	}

	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: targetCloudPath).then { itemExists -> Void in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then {
			return all(self.resolvePath(forItemAt: sourceCloudPath), self.resolveParentPath(forItemAt: targetCloudPath))
		}.then { item, targetParentItem in
			return self.moveFile(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
		}
	}

	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: targetCloudPath).then { itemExists -> Void in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then {
			return all(self.resolvePath(forItemAt: sourceCloudPath), self.resolveParentPath(forItemAt: targetCloudPath))
		}.then { item, targetParentItem in
			return self.moveFolder(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
		}
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: PCloudItem) -> Promise<CloudItemMetadata> {
		if item.itemType == .file {
			return fetchFileMetadata(for: item)
		} else if item.itemType == .folder {
			return fetchFolderMetadata(for: item)
		} else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemMetadata(for: \(item.identifier)) failed with error: \(error)")
			return Promise(error)
		}
	}

	private func fetchFileMetadata(for item: PCloudItem) -> Promise<CloudItemMetadata> {
		assert(item.itemType == .file)
		CloudAccessDDLogDebug("PCloudCloudProvider: fetchFileMetadata(for: \(item.identifier)) called")
		return credential.client.getFileMetadata(item.identifier).execute().then { metadata -> CloudItemMetadata in
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchFileMetadata(for: \(item.identifier)) received metadata: \(metadata)")
			try self.identifierCache.addOrUpdate(item)
			return self.convertToCloudItemMetadata(metadata, at: item.cloudPath)
		}.recover { error -> CloudItemMetadata in
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

	private func fetchFolderMetadata(for item: PCloudItem) -> Promise<CloudItemMetadata> {
		assert(item.itemType == .folder)
		CloudAccessDDLogDebug("PCloudCloudProvider: fetchFolderMetadata(for: \(item.identifier)) called")
		return credential.client.listFolder(item.identifier, recursively: false).execute().then { metadata -> CloudItemMetadata in
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchFolderMetadata(for: \(item.identifier)) received metadata: \(metadata)")
			try self.identifierCache.addOrUpdate(item)
			return self.convertToCloudItemMetadata(metadata, at: item.cloudPath)
		}.recover { error -> CloudItemMetadata in
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

	private func fetchItemList(for item: PCloudItem) -> Promise<CloudItemList> {
		CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemList(for: \(item.identifier)) called")
		guard item.itemType == .folder else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemList(for: \(item.identifier)) failed with error: \(error)")
			return Promise(error)
		}
		return credential.client.listFolder(item.identifier, recursively: false).execute().then { metadata -> CloudItemList in
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemList(for: \(item.identifier)) received metadata: \(metadata)")
			for content in metadata.contents {
				guard let name = content.fileMetadata?.name ?? content.folderMetadata?.name else {
					continue
				}
				let childCloudPath = item.cloudPath.appendingPathComponent(name)
				let childItem = try PCloudItem(cloudPath: childCloudPath, content: content)
				try self.identifierCache.addOrUpdate(childItem)
			}
			return try self.convertToCloudItemList(metadata.contents, at: item.cloudPath)
		}.recover { error -> CloudItemList in
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

	private func downloadFile(for item: PCloudItem, to localURL: URL) -> Promise<Void> {
		CloudAccessDDLogDebug("PCloudCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) called")
		let progress = Progress(totalUnitCount: -1)
		return getFileLink(for: item).then { fileLink -> Promise<URL> in
			return self.downloadFileLink(fileLink, to: localURL, with: progress)
		}.then { _ in
			CloudAccessDDLogDebug("PCloudCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) finished")
			return Promise(())
		}
	}

	private func getFileLink(for item: PCloudItem) -> Promise<FileLink.Metadata> {
		CloudAccessDDLogDebug("PCloudCloudProvider: getFileLink(for: \(item.identifier)) called")
		guard item.itemType == .file else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("PCloudCloudProvider: getFileLink(for: \(item.identifier)) failed with error: \(error)")
			return Promise(error)
		}
		return credential.client.getFileLink(forFile: item.identifier).execute().then { metadata -> FileLink.Metadata in
			CloudAccessDDLogDebug("PCloudCloudProvider: getFileLink(for: \(item.identifier)) received metadata: \(metadata)")
			if let first = metadata.first {
				return first
			} else {
				throw PCloudError.fileLinkNotFound
			}
		}.recover { error -> FileLink.Metadata in
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

	private func downloadFileLink(_ fileLink: FileLink.Metadata, to localURL: URL, with progress: Progress) -> Promise<URL> {
		CloudAccessDDLogDebug("PCloudCloudProvider: downloadFileLink(\(fileLink), to: \(localURL)) called")
		let task = credential.client.downloadFile(from: fileLink.address, downloadTag: fileLink.downloadTag, to: { tmpURL in
			try FileManager.default.moveItem(at: tmpURL, to: localURL)
			return localURL
		})
		task.addProgressBlock { numberOfBytesSent, totalNumberOfBytesToSend in
			progress.totalUnitCount = totalNumberOfBytesToSend
			progress.completedUnitCount = numberOfBytesSent
		}
		return task.execute().then { url -> URL in
			CloudAccessDDLogDebug("PCloudCloudProvider: downloadFileLink(\(fileLink), to: \(localURL)) finished downloading to: \(url)")
			return url
		}.recover { error -> URL in
			CloudAccessDDLogDebug("PCloudCloudProvider: downloadFileLink(\(fileLink), to: \(localURL)) failed with error: \(error)")
			throw error
		}
	}

	private func uploadFile(for parentItem: PCloudItem, from localURL: URL, to cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		CloudAccessDDLogDebug("PCloudCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path)) called")
		let progress = Progress(totalUnitCount: -1)
		let task = credential.client.upload(fromFileAt: localURL, toFolder: parentItem.identifier, asFileNamed: cloudPath.lastPathComponent)
		task.addProgressBlock { numberOfBytesSent, totalNumberOfBytesToSend in
			progress.totalUnitCount = totalNumberOfBytesToSend
			progress.completedUnitCount = numberOfBytesSent
		}
		return task.execute().then { metadata -> CloudItemMetadata in
			CloudAccessDDLogDebug("PCloudCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path)) received metadata: \(metadata)")
			let item = PCloudItem(cloudPath: cloudPath, metadata: metadata)
			try self.identifierCache.addOrUpdate(item)
			return self.convertToCloudItemMetadata(metadata, at: cloudPath)
		}.recover { error -> CloudItemMetadata in
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

	private func createFolder(for parentItem: PCloudItem, with name: String) -> Promise<Void> {
		CloudAccessDDLogDebug("PCloudCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) called")
		return credential.client.createFolder(named: name, inFolder: parentItem.identifier).execute().then { metadata -> Void in
			CloudAccessDDLogDebug("PCloudCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) received metadata: \(metadata)")
			let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
			let item = PCloudItem(cloudPath: cloudPath, metadata: metadata)
			try self.identifierCache.addOrUpdate(item)
		}.recover { error -> Void in
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

	private func deleteFile(for item: PCloudItem) -> Promise<Void> {
		CloudAccessDDLogDebug("PCloudCloudProvider: deleteFile(for: \(item.identifier)) called")
		return credential.client.deleteFile(item.identifier).execute().then { metadata -> Void in
			CloudAccessDDLogDebug("PCloudCloudProvider: deleteFile(for: \(item.identifier)) received metadata: \(metadata)")
			try self.identifierCache.invalidate(item)
		}.recover { error -> Void in
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

	private func deleteFolder(for item: PCloudItem) -> Promise<Void> {
		CloudAccessDDLogDebug("PCloudCloudProvider: deleteFolder(for: \(item.identifier)) called")
		return credential.client.deleteFolderRecursively(item.identifier).execute().then { metadata -> Void in
			CloudAccessDDLogDebug("PCloudCloudProvider: deleteFolder(for: \(item.identifier)) received metadata: \(metadata)")
			try self.identifierCache.invalidate(item)
		}.recover { error -> Void in
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

	private func moveFile(from sourceItem: PCloudItem, toParent targetParentItem: PCloudItem, targetCloudPath: CloudPath) -> Promise<Void> {
		CloudAccessDDLogDebug("PCloudCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		return credential.client.moveFile(sourceItem.identifier, toFolder: targetParentItem.identifier, newName: targetCloudPath.lastPathComponent).execute().then { metadata -> Void in
			CloudAccessDDLogDebug("PCloudCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received metadata: \(metadata)")
			try self.identifierCache.invalidate(sourceItem)
			let targetItem = PCloudItem(cloudPath: targetCloudPath, metadata: metadata)
			try self.identifierCache.addOrUpdate(targetItem)
		}.recover { error -> Void in
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

	private func moveFolder(from sourceItem: PCloudItem, toParent targetParentItem: PCloudItem, targetCloudPath: CloudPath) -> Promise<Void> {
		CloudAccessDDLogDebug("PCloudCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		return credential.client.moveFolder(sourceItem.identifier, toFolder: targetParentItem.identifier, newName: targetCloudPath.lastPathComponent).execute().then { metadata -> Void in
			CloudAccessDDLogDebug("PCloudCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received metadata: \(metadata)")
			try self.identifierCache.invalidate(sourceItem)
			let targetItem = PCloudItem(cloudPath: targetCloudPath, metadata: metadata)
			try self.identifierCache.addOrUpdate(targetItem)
		}.recover { error -> Void in
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

	private func resolvePath(forItemAt cloudPath: CloudPath) -> Promise<PCloudItem> {
		var pathToCheckForCache = cloudPath
		var cachedItem = identifierCache.get(pathToCheckForCache)
		while cachedItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
			pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
			cachedItem = identifierCache.get(pathToCheckForCache)
		}
		guard let item = cachedItem else {
			return Promise(PCloudError.inconsistentCache)
		}
		if pathToCheckForCache != cloudPath {
			return traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: item)
		}
		return Promise(item)
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) -> Promise<PCloudItem> {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		return resolvePath(forItemAt: parentCloudPath).recover { error -> PCloudItem in
			if case CloudProviderError.itemNotFound = error {
				throw CloudProviderError.parentFolderDoesNotExist
			} else {
				throw error
			}
		}
	}

	private func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: PCloudItem) -> Promise<PCloudItem> {
		assert(startCloudPath.pathComponents.count < endCloudPath.pathComponents.count)
		let startIndex = startCloudPath.pathComponents.count
		let endIndex = endCloudPath.pathComponents.count
		var currentPath = startCloudPath
		var parentItem = startItem
		return Promise(on: .global()) { fulfill, _ in
			for i in startIndex ..< endIndex {
				let itemName = endCloudPath.pathComponents[i]
				currentPath = currentPath.appendingPathComponent(itemName)
				parentItem = try awaitPromise(self.getPCloudItem(for: itemName, withParentItem: parentItem))
				try self.identifierCache.addOrUpdate(parentItem)
			}
			fulfill(parentItem)
		}
	}

	private func getPCloudItem(for name: String, withParentItem parentItem: PCloudItem) -> Promise<PCloudItem> {
		CloudAccessDDLogDebug("PCloudCloudProvider: getPCloudItem(for: \(name), withParentItem: \(parentItem.identifier)) called")
		return credential.client.listFolder(parentItem.identifier, recursively: false).execute().then { metadata -> PCloudItem in
			CloudAccessDDLogDebug("PCloudCloudProvider: getPCloudItem(for: \(name), withParentItem: \(parentItem.identifier)) received metadata: \(metadata)")
			guard let content = metadata.contents.first(where: { $0.fileMetadata?.name == name || $0.folderMetadata?.name == name }) else {
				throw CloudProviderError.itemNotFound
			}
			return try PCloudItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), content: content)
		}.recover { error -> PCloudItem in
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
