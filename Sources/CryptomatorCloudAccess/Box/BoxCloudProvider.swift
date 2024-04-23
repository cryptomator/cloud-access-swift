//
//  BoxCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import BoxSDK
import Foundation
import Promises

public class BoxCloudProvider: CloudProvider {
	private let credential: BoxCredential
	private let identifierCache: BoxIdentifierCache
	private let maxPageSize: Int

	public init(credential: BoxCredential, maxPageSize: Int = .max) throws {
		self.credential = credential
		self.identifierCache = try BoxIdentifierCache()
		self.maxPageSize = max(1, min(maxPageSize, 1000))
	}

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		return resolvePath(forItemAt: cloudPath).then { item in
			self.fetchItemMetadata(for: item)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		return resolvePath(forItemAt: cloudPath).then { item in
			self.fetchItemList(for: item, pageToken: pageToken)
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

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata> {
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
		}.then { _ -> Promise<BoxItem> in
			return self.resolveParentPath(forItemAt: cloudPath)
		}.then { parentItem in
			return self.uploadFile(for: parentItem, from: localURL, to: cloudPath)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: cloudPath).then { itemExists in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then { _ -> Promise<BoxItem> in
			return self.resolveParentPath(forItemAt: cloudPath)
		}.then { parentItem in
			return self.createFolder(for: parentItem, with: cloudPath.lastPathComponent)
		}
	}

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		return resolvePath(forItemAt: cloudPath).then { item in
			self.deleteFile(for: item)
		}
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return resolvePath(forItemAt: cloudPath).then { item in
			self.deleteFolder(for: item)
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

	private func fetchItemMetadata(for item: BoxItem) -> Promise<CloudItemMetadata> {
		if item.itemType == .file {
			return fetchFileMetadata(for: item)
		} else if item.itemType == .folder {
			return fetchFolderMetadata(for: item)
		} else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("BoxCloudProvider: fetchItemMetadata(for: \(item.identifier)) failed with error: \(error)")
			return Promise(error)
		}
	}

	private func fetchFileMetadata(for item: BoxItem) -> Promise<CloudItemMetadata> {
		assert(item.itemType == .file)
		CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) called")
		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}
		return Promise { fulfill, reject in
			client.files.get(fileId: item.identifier, fields: ["name", "size", "modified_at"]) { result in
				switch result {
				case let .success(file):
					do {
						let metadata = self.convertToCloudItemMetadata(file, at: item.cloudPath)
						try self.identifierCache.addOrUpdate(item)
						CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) successful")
						fulfill(metadata)
					} catch {
						CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) error: \(error)")
						reject(error)
					}
				case let .failure(error):
					CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) failed with error: \(error)")
					if error.message == .unauthorizedAccess {
						reject(CloudProviderError.unauthorized)
					} else {
						reject(error)
					}
				}
			}
		}
	}

	private func fetchFolderMetadata(for item: BoxItem) -> Promise<CloudItemMetadata> {
		assert(item.itemType == .folder)
		CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) called")
		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}
		return Promise { fulfill, reject in
			client.folders.get(folderId: item.identifier, fields: ["name", "modified_at"]) { result in
				switch result {
				case let .success(folder):
					do {
						let metadata = self.convertToCloudItemMetadata(folder, at: item.cloudPath)
						try self.identifierCache.addOrUpdate(item)
						CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) successful")
						fulfill(metadata)
					} catch {
						CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) error: \(error)")
						reject(error)
					}
				case let .failure(error):
					CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) failed with error: \(error)")
					reject(error)
				}
			}
		}
	}

	private func fetchItemList(for folderItem: BoxItem, pageToken: String?) -> Promise<CloudItemList> {
		guard folderItem.itemType == .folder else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}

		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}

		return Promise { fulfill, reject in
			let iterator = client.folders.listItems(folderId: folderItem.identifier, usemarker: true, marker: pageToken, limit: self.maxPageSize, fields: ["name", "size", "modified_at"])

			iterator.next { result in
				switch result {
				case let .success(page):
					let allItems = page.entries.compactMap { entry -> CloudItemMetadata? in
						switch entry {
						case let .file(file):
							return self.convertToCloudItemMetadata(file, at: folderItem.cloudPath.appendingPathComponent(file.name ?? ""))
						case let .folder(folder):
							return self.convertToCloudItemMetadata(folder, at: folderItem.cloudPath.appendingPathComponent(folder.name ?? ""))
						case .webLink:
							// Handling of web links as required
							return nil
						}
					}

					fulfill(CloudItemList(items: allItems, nextPageToken: page.nextMarker))

				case let .failure(error):
					reject(CloudProviderError.pageTokenInvalid)
				}
			}
		}
	}

	private func downloadFile(for item: BoxItem, to localURL: URL) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) called")
		guard item.itemType == .file else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}

		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}

		return Promise { fulfill, reject in
			client.files.download(fileId: item.identifier, destinationURL: localURL) { result in
				switch result {
				case .success:
					CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) finished downloading")
					fulfill(())
				case let .failure(error):
					CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) failed with error: \(error)")
					if error.message == .unauthorizedAccess {
						reject(CloudProviderError.unauthorized)
					} else {
						reject(error)
					}
				}
			}
		}
	}

	private func uploadFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}

		return Promise { fulfill, reject in
			let targetFileName = cloudPath.lastPathComponent

			guard let data = try? Data(contentsOf: localURL) else {
				reject(CloudProviderError.itemNotFound)
				return
			}

			self.resolvePath(forItemAt: cloudPath).then { existingItem -> Void in
				client.files.uploadVersion(forFile: existingItem.identifier, data: data, completion: { result in
					switch result {
					case let .success(updatedFile):
						let metadata = self.convertToCloudItemMetadata(updatedFile, at: cloudPath)
						fulfill(metadata)
					case let .failure(error):
						reject(error)
					}
				})
			}.recover { error -> Void in
				guard case CloudProviderError.itemNotFound = error else {
					throw error
				}
				client.files.upload(data: data, name: targetFileName, parentId: parentItem.identifier, completion: { result in
					switch result {
					case let .success(newFile):
						let metadata = self.convertToCloudItemMetadata(newFile, at: cloudPath)
						fulfill(metadata)
					case let .failure(error):
						if error.message == .unauthorizedAccess {
							reject(CloudProviderError.unauthorized)
						} else {
							reject(error)
						}
					}
				})
			}
		}
	}

	private func createFolder(for parentItem: BoxItem, with name: String) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) called")
		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}
		return Promise { fulfill, reject in
			client.folders.create(name: name, parentId: parentItem.identifier) { result in
				switch result {
				case let .success(folder):
					CloudAccessDDLogDebug("BoxCloudProvider: createFolder successful with folder ID: \(folder.id)")
					do {
						let newItem = BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: folder.id, itemType: .folder)
						try self.identifierCache.addOrUpdate(newItem)
						fulfill(())
					} catch {
						reject(error)
					}
				case let .failure(error):
					CloudAccessDDLogDebug("BoxCloudProvider: createFolder failed with error: \(error.localizedDescription)")
					if error.message == .unauthorizedAccess {
						reject(CloudProviderError.unauthorized)
					} else {
						reject(error)
					}
				}
			}
		}
	}

	private func deleteFile(for item: BoxItem) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) called")
		guard item.itemType == .file else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}

		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}

		return Promise<Void> { fulfill, reject in
			client.files.delete(fileId: item.identifier) { result in
				switch result {
				case .success:
					CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) succeeded")
					do {
						try self.identifierCache.invalidate(item)
						fulfill(())
					} catch {
						CloudAccessDDLogDebug("BoxCloudProvider: Cache update failed with error: \(error)")
						reject(error)
					}
				case let .failure(error):
					CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) failed with error: \(error)")
					if case BoxSDKErrorEnum.notFound = error.message {
						reject(CloudProviderError.itemNotFound)
					} else {
						if error.message == .unauthorizedAccess {
							reject(CloudProviderError.unauthorized)
						} else {
							reject(error)
						}
					}
				}
			}
		}
	}

	private func deleteFolder(for item: BoxItem) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) called")
		guard item.itemType == .folder else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}

		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}

		return Promise<Void> { fulfill, reject in
			client.folders.delete(folderId: item.identifier, recursive: true) { result in
				switch result {
				case .success:
					CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) succeeded")
					do {
						try self.identifierCache.invalidate(item)
						fulfill(())
					} catch {
						CloudAccessDDLogDebug("BoxCloudProvider: Cache update failed with error: \(error)")
						reject(error)
					}
				case let .failure(error):
					CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) failed with error: \(error)")
					if case BoxSDKErrorEnum.notFound = error.message {
						reject(CloudProviderError.itemNotFound)
					} else {
						if error.message == .unauthorizedAccess {
							reject(CloudProviderError.unauthorized)
						} else {
							reject(error)
						}
					}
				}
			}
		}
	}

	private func moveFile(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}

		return Promise<Void> { fulfill, reject in
			let newName = targetCloudPath.lastPathComponent
			client.files.update(fileId: sourceItem.identifier, name: newName, parentId: targetParentItem.identifier) { result in
				switch result {
				case .success:
					CloudAccessDDLogDebug("BoxCloudProvider: moveFile succeeded for \(sourceItem.identifier) to \(targetCloudPath.path)")
					do {
						try self.identifierCache.invalidate(sourceItem)
						let newItem = BoxItem(cloudPath: targetCloudPath, identifier: sourceItem.identifier, itemType: sourceItem.itemType)
						try self.identifierCache.addOrUpdate(newItem)
						fulfill(())
					} catch {
						reject(error)
					}
				case let .failure(error):
					CloudAccessDDLogDebug("BoxCloudProvider: moveFile failed for \(sourceItem.identifier) with error: \(error)")
					if error.message == .unauthorizedAccess {
						reject(CloudProviderError.unauthorized)
					} else {
						reject(error)
					}
				}
			}
		}
	}

	private func moveFolder(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}

		return Promise<Void> { fulfill, reject in
			let newName = targetCloudPath.lastPathComponent
			client.folders.update(folderId: sourceItem.identifier, name: newName, parentId: targetParentItem.identifier) { result in
				switch result {
				case .success:
					CloudAccessDDLogDebug("BoxCloudProvider: moveFolder succeeded for \(sourceItem.identifier) to \(targetCloudPath.path)")
					do {
						try self.identifierCache.invalidate(sourceItem)
						let newItem = BoxItem(cloudPath: targetCloudPath, identifier: sourceItem.identifier, itemType: sourceItem.itemType)
						try self.identifierCache.addOrUpdate(newItem)
						fulfill(())
					} catch {
						reject(error)
					}
				case let .failure(error):
					CloudAccessDDLogDebug("BoxCloudProvider: moveFolder failed for \(sourceItem.identifier) with error: \(error)")
					if error.message == .unauthorizedAccess {
						reject(CloudProviderError.unauthorized)
					} else {
						reject(error)
					}
				}
			}
		}
	}

	// MARK: - Resolve Path

	private func resolvePath(forItemAt cloudPath: CloudPath) -> Promise<BoxItem> {
		var pathToCheckForCache = cloudPath
		var cachedItem = identifierCache.get(pathToCheckForCache)
		while cachedItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
			pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
			cachedItem = identifierCache.get(pathToCheckForCache)
		}
		guard let item = cachedItem else {
			return Promise(BoxError.inconsistentCache)
		}
		if pathToCheckForCache != cloudPath {
			return traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: item)
		}
		return Promise(item)
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) -> Promise<BoxItem> {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		return resolvePath(forItemAt: parentCloudPath).recover { error -> BoxItem in
			if case CloudProviderError.itemNotFound = error {
				throw CloudProviderError.parentFolderDoesNotExist
			} else {
				throw error
			}
		}
	}

	private func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: BoxItem) -> Promise<BoxItem> {
		assert(startCloudPath.pathComponents.count < endCloudPath.pathComponents.count)
		let startIndex = startCloudPath.pathComponents.count
		let endIndex = endCloudPath.pathComponents.count
		var currentPath = startCloudPath
		var parentItem = startItem
		return Promise(on: .global()) { fulfill, _ in
			for i in startIndex ..< endIndex {
				let itemName = endCloudPath.pathComponents[i]
				currentPath = currentPath.appendingPathComponent(itemName)
				parentItem = try awaitPromise(self.getBoxItem(for: itemName, withParentItem: parentItem))
				try self.identifierCache.addOrUpdate(parentItem)
			}
			fulfill(parentItem)
		}
	}

	func getBoxItem(for name: String, withParentItem parentItem: BoxItem) -> Promise<BoxItem> {
		guard let client = credential.client else {
			return Promise(CloudProviderError.unauthorized)
		}

		return Promise { fulfill, reject in
			CloudAccessDDLogDebug("BoxCloudProvider: getBoxItem(for: \(name), withParentItem: \(parentItem.identifier)) called")

			let iterator = client.folders.listItems(folderId: parentItem.identifier)
			iterator.next { result in
				switch result {
				case let .success(page):
					for item in page.entries {
						do {
							if let mappedItem = try self.mapFolderItemToBoxItem(name: name, parentItem: parentItem, item: item) {
								fulfill(mappedItem)
								return
							}
						} catch {
							reject(error)
							return
						}
					}
					reject(CloudProviderError.itemNotFound)
				case let .failure(error):
					if error.message == .unauthorizedAccess {
						reject(CloudProviderError.unauthorized)
					} else {
						reject(error)
					}
				}
			}
		}
	}

	func mapFolderItemToBoxItem(name: String, parentItem: BoxItem, item: FolderItem) throws -> BoxItem? {
		switch item {
		case let .file(file) where file.name == name:
			return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), file: file)
		case let .folder(folder) where folder.name == name:
			return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), folder: folder)
		case .webLink:
			throw BoxError.unexpectedContent
		default:
			return nil
		}
	}

	// MARK: - Helpers

	private func convertToCloudItemMetadata(_ content: FolderItem, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		switch content {
		case let .file(fileMetadata):
			return convertToCloudItemMetadata(fileMetadata, at: cloudPath)
		case let .folder(folderMetadata):
			return convertToCloudItemMetadata(folderMetadata, at: cloudPath)
		default:
			throw BoxError.unexpectedContent
		}
	}

	private func convertToCloudItemMetadata(_ metadata: File, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = metadata.name ?? ""
		let itemType = CloudItemType.file
		let lastModifiedDate = metadata.modifiedAt
		let size = metadata.size
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
	}

	private func convertToCloudItemMetadata(_ metadata: Folder, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = metadata.name ?? ""
		let itemType = CloudItemType.folder
		let lastModifiedDate = metadata.modifiedAt
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: nil)
	}

	private func convertToCloudItemList(_ contents: [FolderItem], at cloudPath: CloudPath) throws -> CloudItemList {
		var items = [CloudItemMetadata]()
		for content in contents {
			switch content {
			case let .file(fileMetadata):
				let itemCloudPath = cloudPath.appendingPathComponent(fileMetadata.name ?? "")
				let itemMetadata = convertToCloudItemMetadata(fileMetadata, at: itemCloudPath)
				items.append(itemMetadata)
			case let .folder(folderMetadata):
				let itemCloudPath = cloudPath.appendingPathComponent(folderMetadata.name ?? "")
				let itemMetadata = convertToCloudItemMetadata(folderMetadata, at: itemCloudPath)
				items.append(itemMetadata)
			default:
				throw BoxError.unexpectedContent
			}
		}
		return CloudItemList(items: items, nextPageToken: nil)
	}
}
