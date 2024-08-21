//
//  BoxCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import BoxSdkGen
import Foundation
import Promises

public class BoxCloudProvider: CloudProvider {
	private let client: BoxClient
	private let identifierCache: BoxIdentifierCache
	private let maxPageSize: Int

	public init(credential: BoxCredential, maxPageSize: Int = .max, urlSessionConfiguration: URLSessionConfiguration) throws {
		let networkSession = NetworkSession(configuration: urlSessionConfiguration)
		self.client = BoxClient(auth: credential.auth, networkSession: networkSession)
		self.identifierCache = try BoxIdentifierCache()
		self.maxPageSize = max(1, min(maxPageSize, 1000))
	}

	public convenience init(credential: BoxCredential, maxPageSize: Int = .max) throws {
		try self.init(credential: credential, maxPageSize: maxPageSize, urlSessionConfiguration: .default)
	}

	public static func withBackgroundSession(credential: BoxCredential, maxPageSize: Int = .max, sessionIdentifier: String) throws -> BoxCloudProvider {
		let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
		configuration.sharedContainerIdentifier = BoxSetup.constants.sharedContainerIdentifier
		return try BoxCloudProvider(credential: credential, maxPageSize: maxPageSize, urlSessionConfiguration: configuration)
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
		return resolveParentPath(forItemAt: cloudPath).then { parentItem in
			return self.uploadFile(for: parentItem, from: localURL, to: cloudPath, replaceExisting: replaceExisting)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: cloudPath).then { itemExists -> Void in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then {
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
		CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item)) called")
		let pendingPromise = Promise<CloudItemMetadata>.pending()
		_Concurrency.Task {
			do {
				let file = try await client.files.getFileById(fileId: item.identifier)
				CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) received file: \(file)")
				let cloudItemMetadata = convertToCloudItemMetadata(file, at: item.cloudPath)
				pendingPromise.fulfill(cloudItemMetadata)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func fetchFolderMetadata(for item: BoxItem) -> Promise<CloudItemMetadata> {
		assert(item.itemType == .folder)
		CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) called")
		let pendingPromise = Promise<CloudItemMetadata>.pending()
		_Concurrency.Task {
			do {
				let folder = try await client.folders.getFolderById(folderId: item.identifier)
				CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) received folder: \(folder)")
				let cloudItemMetadata = convertToCloudItemMetadata(folder, at: item.cloudPath)
				pendingPromise.fulfill(cloudItemMetadata)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func fetchItemList(for folderItem: BoxItem, pageToken: String?) -> Promise<CloudItemList> {
		guard folderItem.itemType == .folder else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		let pendingPromise = Promise<CloudItemList>.pending()
		_Concurrency.Task {
			do {
				let queryParams = GetFolderItemsQueryParams(fields: ["name", "size", "modified_at"], usemarker: true, marker: pageToken, limit: Int64(self.maxPageSize))
				let items = try await client.folders.getFolderItems(folderId: folderItem.identifier, queryParams: queryParams)
				CloudAccessDDLogDebug("BoxCloudProvider: fetchItemList(for: \(folderItem.identifier), pageToken: \(pageToken ?? "nil")) received items: \(items)")
				let cloudItemList = try convertToCloudItemList(items, at: folderItem.cloudPath)
				pendingPromise.fulfill(cloudItemList)
			} catch let error as BoxAPIError where error.responseInfo.statusCode == 400 {
				pendingPromise.reject(CloudProviderError.pageTokenInvalid)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: fetchItemList(for: \(folderItem.identifier), pageToken: \(pageToken ?? "nil")) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func downloadFile(for item: BoxItem, to localURL: URL) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) called")
		guard item.itemType == .file else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		let pendingPromise = Promise<Void>.pending()
		_Concurrency.Task {
			do {
				let url = try await client.downloads.downloadFile(fileId: item.identifier, downloadDestinationURL: localURL)
				CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) finished downloading to: \(url)")
				pendingPromise.fulfill(())
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func uploadFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		CloudAccessDDLogDebug("BoxCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath), replaceExisting: \(replaceExisting)) called")
		let attributes: [FileAttributeKey: Any]
		do {
			attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
		} catch CocoaError.fileReadNoSuchFile {
			return Promise(CloudProviderError.itemNotFound)
		} catch {
			return Promise(error)
		}
		let fileSize = attributes[FileAttributeKey.size] as? Int ?? 52_428_800
		// Box recommends uploading files over 50 MiB with a chunked upload.
		return resolvePath(forItemAt: cloudPath).then { item -> Promise<CloudItemMetadata> in
			if !replaceExisting || (replaceExisting && item.itemType == .folder) {
				throw CloudProviderError.itemAlreadyExists
			}
			if fileSize >= 52_428_800 {
				return self.uploadLargeExistingFile(for: item, from: localURL, to: cloudPath, fileSize: fileSize)
			} else {
				return self.uploadSmallExistingFile(for: item, from: localURL, to: cloudPath)
			}
		}.recover { error -> Promise<CloudItemMetadata> in
			guard case CloudProviderError.itemNotFound = error else {
				throw error
			}
			if fileSize >= 52_428_800 {
				return self.uploadLargeNewFile(for: parentItem, from: localURL, to: cloudPath, fileSize: fileSize)
			} else {
				return self.uploadSmallNewFile(for: parentItem, from: localURL, to: cloudPath)
			}
		}
	}

	private func uploadSmallNewFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let pendingPromise = Promise<CloudItemMetadata>.pending()
		_Concurrency.Task {
			do {
				guard let fileStream = InputStream(url: localURL) else {
					throw CloudProviderError.itemNotFound
				}
				let requestBody = UploadFileRequestBody(
					attributes: UploadFileRequestBodyAttributesField(
						name: cloudPath.lastPathComponent,
						parent: UploadFileRequestBodyAttributesParentField(id: parentItem.identifier)
					),
					file: fileStream
				)
				let files = try await client.uploads.uploadFile(requestBody: requestBody)
				guard let file = files.entries?.first else {
					throw CloudProviderError.itemNotFound
				}
				CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallNewFile(for: \(parentItem.identifier), to: \(cloudPath)) received file: \(file)")
				let cloudItemMetadata = convertToCloudItemMetadata(file, at: cloudPath)
				pendingPromise.fulfill(cloudItemMetadata)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallNewFile(for: \(parentItem.identifier), to: \(cloudPath)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func uploadSmallExistingFile(for existingItem: BoxItem, from localURL: URL, to cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let pendingPromise = Promise<CloudItemMetadata>.pending()
		_Concurrency.Task {
			do {
				guard let fileStream = InputStream(url: localURL) else {
					throw CloudProviderError.itemNotFound
				}
				let requestBody = UploadFileVersionRequestBody(
					attributes: UploadFileVersionRequestBodyAttributesField(name: cloudPath.lastPathComponent),
					file: fileStream
				)
				let files = try await client.uploads.uploadFileVersion(fileId: existingItem.identifier, requestBody: requestBody)
				guard let file = files.entries?.first else {
					throw CloudProviderError.itemNotFound
				}
				CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallExistingFile(for: \(existingItem.identifier), to: \(cloudPath)) received file: \(file)")
				let cloudItemMetadata = convertToCloudItemMetadata(file, at: cloudPath)
				pendingPromise.fulfill(cloudItemMetadata)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallExistingFile(for: \(existingItem.identifier), to: \(cloudPath)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func uploadLargeNewFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, fileSize: Int) -> Promise<CloudItemMetadata> {
		let pendingPromise = Promise<CloudItemMetadata>.pending()
		_Concurrency.Task {
			do {
				let requestBody = CreateFileUploadSessionRequestBody(folderId: parentItem.identifier, fileSize: Int64(fileSize), fileName: cloudPath.lastPathComponent)
				let uploadSession = try await self.client.chunkedUploads.createFileUploadSession(requestBody: requestBody)
				let cloudItemMetadata = try await uploadLargeFile(for: uploadSession, from: localURL, to: cloudPath, fileSize: fileSize)
				pendingPromise.fulfill(cloudItemMetadata)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: uploadLargeNewFile(for: \(parentItem.identifier), to: \(cloudPath), fileSize: \(fileSize)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func uploadLargeExistingFile(for existingItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, fileSize: Int) -> Promise<CloudItemMetadata> {
		let pendingPromise = Promise<CloudItemMetadata>.pending()
		_Concurrency.Task {
			do {
				let requestBody = CreateFileUploadSessionForExistingFileRequestBody(fileSize: Int64(fileSize))
				let uploadSession = try await client.chunkedUploads.createFileUploadSessionForExistingFile(fileId: existingItem.identifier, requestBody: requestBody)
				let cloudItemMetadata = try await uploadLargeFile(for: uploadSession, from: localURL, to: cloudPath, fileSize: fileSize)
				pendingPromise.fulfill(cloudItemMetadata)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: uploadLargeExistingFile(for: \(existingItem.identifier), to: \(cloudPath), fileSize: \(fileSize)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func uploadLargeFile(for uploadSession: UploadSession, from localURL: URL, to cloudPath: CloudPath, fileSize: Int) async throws -> CloudItemMetadata {
		guard let fileStream = InputStream(url: localURL) else {
			throw CloudProviderError.itemNotFound
		}
		guard let uploadSessionId = uploadSession.id, let partSize = uploadSession.partSize else {
			throw BoxSDKError(message: "Failed to retrieve upload session data")
		}
		let fileHash = Hash(algorithm: .sha1)
		let chunksIterator = Utils.iterateChunks(stream: fileStream, chunkSize: partSize)
		let results = try await Utils.reduceIterator(iterator: chunksIterator, reducer: client.chunkedUploads.reducer, initialValue: PartAccumulator(lastIndex: -1, parts: [], fileSize: Int64(fileSize), uploadSessionId: uploadSessionId, fileHash: fileHash))
		let sha1 = await fileHash.digestHash(encoding: "base64")
		let digest = "\("sha=")\(sha1)"
		let committedSession = try await client.chunkedUploads.createFileUploadSessionCommit(uploadSessionId: uploadSessionId, requestBody: CreateFileUploadSessionCommitRequestBody(parts: results.parts), headers: CreateFileUploadSessionCommitHeaders(digest: digest))
		guard let file = committedSession.entries?.first else {
			throw CloudProviderError.itemNotFound
		}
		CloudAccessDDLogDebug("BoxCloudProvider: uploadLargeFile(for: \(uploadSession), to: \(cloudPath), fileSize: \(fileSize)) received file: \(file)")
		return convertToCloudItemMetadata(file, at: cloudPath)
	}

	private func createFolder(for parentItem: BoxItem, with name: String) -> Promise<Void> {
		let pendingPromise = Promise<Void>.pending()
		_Concurrency.Task {
			do {
				let requestBody = CreateFolderRequestBody(name: name, parent: CreateFolderRequestBodyParentField(id: parentItem.identifier))
				let folder = try await client.folders.createFolder(requestBody: requestBody)
				CloudAccessDDLogDebug("BoxCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) received folder: \(folder)")
				let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
				let item = BoxItem(cloudPath: cloudPath, folder: folder)
				try self.identifierCache.addOrUpdate(item)
				pendingPromise.fulfill(())
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func deleteFile(for item: BoxItem) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) called")
		guard item.itemType == .file else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		let pendingPromise = Promise<Void>.pending()
		_Concurrency.Task {
			do {
				try await client.files.deleteFileById(fileId: item.identifier)
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) succeeded")
				try self.identifierCache.invalidate(item)
				pendingPromise.fulfill(())
			} catch let error as BoxAPIError where error.responseInfo.statusCode == 404 {
				pendingPromise.reject(CloudProviderError.itemNotFound)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func deleteFolder(for item: BoxItem) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) called")
		guard item.itemType == .folder else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		let pendingPromise = Promise<Void>.pending()
		_Concurrency.Task {
			do {
				let queryParams = DeleteFolderByIdQueryParams(recursive: true)
				try await client.folders.deleteFolderById(folderId: item.identifier, queryParams: queryParams)
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) succeeded")
				try self.identifierCache.invalidate(item)
				pendingPromise.fulfill(())
			} catch let error as BoxAPIError where error.responseInfo.statusCode == 404 {
				pendingPromise.reject(CloudProviderError.itemNotFound)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func moveFile(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		let pendingPromise = Promise<Void>.pending()
		_Concurrency.Task {
			do {
				let requestBody = UpdateFileByIdRequestBody(
					name: targetCloudPath.lastPathComponent,
					parent: UpdateFileByIdRequestBodyParentField(id: targetParentItem.identifier)
				)
				let file = try await client.files.updateFileById(fileId: sourceItem.identifier, requestBody: requestBody)
				CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received file: \(file)")
				try self.identifierCache.invalidate(sourceItem)
				let targetItem = BoxItem(cloudPath: targetCloudPath, file: file)
				try self.identifierCache.addOrUpdate(targetItem)
				pendingPromise.fulfill(())
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	private func moveFolder(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		let pendingPromise = Promise<Void>.pending()
		_Concurrency.Task {
			do {
				let requestBody = UpdateFolderByIdRequestBody(
					name: targetCloudPath.lastPathComponent,
					parent: UpdateFolderByIdRequestBodyParentField(id: targetParentItem.identifier)
				)
				let folder = try await client.folders.updateFolderById(folderId: sourceItem.identifier, requestBody: requestBody)
				CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received folder: \(folder)")
				try self.identifierCache.invalidate(sourceItem)
				let newItem = BoxItem(cloudPath: targetCloudPath, folder: folder)
				try self.identifierCache.addOrUpdate(newItem)
				pendingPromise.fulfill(())
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
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
		let pendingPromise = Promise<BoxItem>.pending()
		_Concurrency.Task {
			do {
				let foundItem = try await findBoxItem(in: parentItem, withName: name, marker: nil)
				pendingPromise.fulfill(foundItem)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: getBoxItem(for: \(name), withParentItem: \(parentItem.identifier)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(convertStandardError(error))
			}
		}
		return pendingPromise
	}

	func findBoxItem(in parentItem: BoxItem, withName name: String, marker: String?) async throws -> BoxItem {
		let queryParams = GetFolderItemsQueryParams(fields: ["name", "size", "modified_at"], usemarker: true, marker: marker, limit: Int64(maxPageSize))
		let items = try await client.folders.getFolderItems(folderId: parentItem.identifier, queryParams: queryParams)
		CloudAccessDDLogDebug("BoxCloudProvider: getBoxItem(for: \(name), withParentItem: \(parentItem.identifier)) received items: \(items)")
		if let foundItem = try await locateBoxItem(in: items, withName: name, parentItem: parentItem) {
			return foundItem
		} else if let nextMarker = items.nextMarker {
			return try await findBoxItem(in: parentItem, withName: name, marker: nextMarker)
		} else {
			throw CloudProviderError.itemNotFound
		}
	}

	func locateBoxItem(in items: Items, withName name: String, parentItem: BoxItem) async throws -> BoxItem? {
		if let entries = items.entries {
			for entry in entries {
				switch entry {
				case let .fileFull(file) where file.name == name:
					return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), file: file)
				case let .folderMini(folder) where folder.name == name:
					return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), folder: folder)
				case .webLink, .fileFull, .folderMini:
					continue
				}
			}
		}
		return nil
	}

	// MARK: - Helpers

	private func convertToCloudItemMetadata(_ file: File, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = file.name ?? ""
		let itemType = CloudItemType.file
		let size = file.size.map { Int($0) }
		let lastModifiedDate = file.modifiedAt
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
	}

	private func convertToCloudItemMetadata(_ folder: FolderMini, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = folder.name ?? ""
		let itemType = CloudItemType.folder
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: nil, size: nil)
	}

	private func convertToCloudItemList(_ folderItems: Items, at cloudPath: CloudPath) throws -> CloudItemList {
		var items = [CloudItemMetadata]()
		guard let entries = folderItems.entries else {
			return CloudItemList(items: [])
		}
		for entry in entries {
			switch entry {
			case let .fileFull(file):
				let itemCloudPath = cloudPath.appendingPathComponent(file.name ?? "")
				let itemMetadata = convertToCloudItemMetadata(file, at: itemCloudPath)
				items.append(itemMetadata)
			case let .folderMini(folder):
				let itemCloudPath = cloudPath.appendingPathComponent(folder.name ?? "")
				let itemMetadata = convertToCloudItemMetadata(folder, at: itemCloudPath)
				items.append(itemMetadata)
			default:
				throw BoxError.unexpectedContent
			}
		}
		return CloudItemList(items: items, nextPageToken: folderItems.nextMarker)
	}

	private func convertStandardError(_ error: Error) -> Error {
		switch error {
		case let error as BoxAPIError where error.responseInfo.statusCode == 401:
			return CloudProviderError.unauthorized
		default:
			return error
		}
	}
}
