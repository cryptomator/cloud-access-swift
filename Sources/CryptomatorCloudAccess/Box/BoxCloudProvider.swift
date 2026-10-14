//
//  BoxCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

@preconcurrency import BoxSdkGen
import CryptoKit
import Foundation

/// Safe to share across threads, because `BoxClient` is immutable and each of its requests is an independent async call.
public final class BoxCloudProvider: CloudProvider {
	private let client: BoxClient
	private let identifierCache: BoxIdentifierCache
	private let maxPageSize: Int

	public init(credential: BoxCredential, maxPageSize: Int = .max, urlSessionConfiguration: URLSessionConfiguration) throws {
		let networkSession = NetworkSession(networkClient: BoxURLSessionNetworkClient(configuration: urlSessionConfiguration))
		self.client = BoxClient(auth: credential.client.auth, networkSession: networkSession)
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

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try _Concurrency.Task.checkCancellation()
		let item = try await resolvePath(forItemAt: cloudPath)
		try _Concurrency.Task.checkCancellation()
		return try await fetchItemMetadata(for: item)
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try _Concurrency.Task.checkCancellation()
		let item = try await resolvePath(forItemAt: cloudPath)
		try _Concurrency.Task.checkCancellation()
		return try await fetchItemList(for: item, pageToken: pageToken)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try _Concurrency.Task.checkCancellation()
		let phases = Progress.phases(of: progress, 999)
		let item = try await resolvePath(forItemAt: cloudPath)
		try _Concurrency.Task.checkCancellation()
		let metadata = try await downloadFile(for: item, to: localURL)
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try _Concurrency.Task.checkCancellation()
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
		let metadata = try await uploadFile(for: parentItem, from: localURL, to: cloudPath, replaceExisting: replaceExisting)
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try _Concurrency.Task.checkCancellation()
		if try await checkForItemExistence(at: cloudPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let parentItem = try await resolveParentPath(forItemAt: cloudPath)
		try _Concurrency.Task.checkCancellation()
		try await createFolder(for: parentItem, with: cloudPath.lastPathComponent)
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		try _Concurrency.Task.checkCancellation()
		let item = try await resolvePath(forItemAt: cloudPath)
		try _Concurrency.Task.checkCancellation()
		try await deleteFile(for: item)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try _Concurrency.Task.checkCancellation()
		let item = try await resolvePath(forItemAt: cloudPath)
		try _Concurrency.Task.checkCancellation()
		try await deleteFolder(for: item)
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try _Concurrency.Task.checkCancellation()
		if try await checkForItemExistence(at: targetCloudPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let item = try await resolvePath(forItemAt: sourceCloudPath)
		let targetParentItem = try await resolveParentPath(forItemAt: targetCloudPath)
		try _Concurrency.Task.checkCancellation()
		try await moveFile(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try _Concurrency.Task.checkCancellation()
		if try await checkForItemExistence(at: targetCloudPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let item = try await resolvePath(forItemAt: sourceCloudPath)
		let targetParentItem = try await resolveParentPath(forItemAt: targetCloudPath)
		try _Concurrency.Task.checkCancellation()
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
			let file = try await withBoxSDKCancellationShield { try await self.client.files.getFileById(fileId: item.identifier) }
			CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) received file: \((try? file.serializeToString()) ?? file)")
			return convertToCloudItemMetadata(file, at: item.cloudPath)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func fetchFolderMetadata(for item: BoxItem) async throws -> CloudItemMetadata {
		assert(item.itemType == .folder)
		CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) called")
		do {
			let folder = try await withBoxSDKCancellationShield { try await self.client.folders.getFolderById(folderId: item.identifier) }
			CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) received folder: \((try? folder.serializeToString()) ?? folder)")
			return convertToCloudItemMetadata(folder, at: item.cloudPath)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func fetchItemList(for folderItem: BoxItem, pageToken: String?) async throws -> CloudItemList {
		guard folderItem.itemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
		do {
			let queryParams = GetFolderItemsQueryParams(fields: ["name", "size", "modified_at"], usemarker: true, marker: pageToken, limit: Int64(maxPageSize))
			let items = try await withBoxSDKCancellationShield { try await self.client.folders.getFolderItems(folderId: folderItem.identifier, queryParams: queryParams) }
			CloudAccessDDLogDebug("BoxCloudProvider: fetchItemList(for: \(folderItem.identifier), pageToken: \(pageToken ?? "nil")) received items: \((try? items.serializeToString()) ?? items)")
			return try convertToCloudItemList(items, at: folderItem.cloudPath)
		} catch let error as BoxAPIError where error.responseInfo.statusCode == 400 {
			throw CloudProviderError.pageTokenInvalid
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: fetchItemList(for: \(folderItem.identifier), pageToken: \(pageToken ?? "nil")) failed with error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func downloadFile(for item: BoxItem, to localURL: URL) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) called")
		guard item.itemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		let remoteMetadata = try await fetchFileMetadata(for: item)
		try _Concurrency.Task.checkCancellation()
		return try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			do {
				// The download returns no URL if the file isn't ready for download yet.
				guard let url = try await withBoxSDKCancellationShield({ try await self.client.downloads.downloadFile(fileId: item.identifier, downloadDestinationUrl: stagedFile) }) else {
					throw BoxSDKError(message: "File is not ready for download")
				}
				CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) finished downloading to: \(url)")
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) failed with error: \(error.localizedDescription)")
				throw convertStandardError(error)
			}
			return remoteMetadata
		})
	}

	private func uploadFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("BoxCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath), replaceExisting: \(replaceExisting)) called")
		let attributes: [FileAttributeKey: Any]
		do {
			attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
		} catch CocoaError.fileReadNoSuchFile {
			throw CloudProviderError.itemNotFound
		}
		let fileSize = attributes[FileAttributeKey.size] as? Int ?? 52_428_800
		// Box recommends uploading files over 50 MiB with a chunked upload.
		do {
			let item = try await resolvePath(forItemAt: cloudPath)
			if !replaceExisting || (replaceExisting && item.itemType == .folder) {
				throw CloudProviderError.itemAlreadyExists
			}
			try _Concurrency.Task.checkCancellation()
			if fileSize >= 52_428_800 {
				return try await uploadLargeExistingFile(for: item, from: localURL, to: cloudPath, fileSize: fileSize)
			} else {
				return try await uploadSmallExistingFile(for: item, from: localURL, to: cloudPath)
			}
		} catch CloudProviderError.itemNotFound {
			try _Concurrency.Task.checkCancellation()
			if fileSize >= 52_428_800 {
				return try await uploadLargeNewFile(for: parentItem, from: localURL, to: cloudPath, fileSize: fileSize)
			} else {
				return try await uploadSmallNewFile(for: parentItem, from: localURL, to: cloudPath)
			}
		}
	}

	private func uploadSmallNewFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath) async throws -> CloudItemMetadata {
		do {
			let requestBody = try UploadFileRequestBody(
				attributes: UploadFileRequestBodyAttributesField(
					name: cloudPath.lastPathComponent,
					parent: UploadFileRequestBodyAttributesParentField(id: parentItem.identifier)
				),
				file: createInputStream(for: localURL)
			)
			let files = try await withBoxSDKCancellationShield { try await self.client.uploads.uploadFile(requestBody: requestBody) }
			guard let file = files.entries?.first else {
				throw CloudProviderError.itemNotFound
			}
			CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallNewFile(for: \(parentItem.identifier), to: \(cloudPath)) received file: \((try? file.serializeToString()) ?? file)")
			return convertToCloudItemMetadata(file, at: cloudPath)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallNewFile(for: \(parentItem.identifier), to: \(cloudPath)) failed with error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func uploadSmallExistingFile(for existingItem: BoxItem, from localURL: URL, to cloudPath: CloudPath) async throws -> CloudItemMetadata {
		do {
			let requestBody = try UploadFileVersionRequestBody(
				attributes: UploadFileVersionRequestBodyAttributesField(name: cloudPath.lastPathComponent),
				file: createInputStream(for: localURL)
			)
			let files = try await withBoxSDKCancellationShield { try await self.client.uploads.uploadFileVersion(fileId: existingItem.identifier, requestBody: requestBody) }
			guard let file = files.entries?.first else {
				throw CloudProviderError.itemNotFound
			}
			CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallExistingFile(for: \(existingItem.identifier), to: \(cloudPath)) received file: \((try? file.serializeToString()) ?? file)")
			return convertToCloudItemMetadata(file, at: cloudPath)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: uploadSmallExistingFile(for: \(existingItem.identifier), to: \(cloudPath)) failed with error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func uploadLargeNewFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, fileSize: Int) async throws -> CloudItemMetadata {
		do {
			let requestBody = CreateFileUploadSessionRequestBody(folderId: parentItem.identifier, fileSize: Int64(fileSize), fileName: cloudPath.lastPathComponent)
			let uploadSession = try await withBoxSDKCancellationShield { try await self.client.chunkedUploads.createFileUploadSession(requestBody: requestBody) }
			return try await uploadLargeFile(for: uploadSession, from: localURL, to: cloudPath, fileSize: fileSize)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: uploadLargeNewFile(for: \(parentItem.identifier), to: \(cloudPath), fileSize: \(fileSize)) failed with error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func uploadLargeExistingFile(for existingItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, fileSize: Int) async throws -> CloudItemMetadata {
		do {
			let requestBody = CreateFileUploadSessionForExistingFileRequestBody(fileSize: Int64(fileSize))
			let uploadSession = try await withBoxSDKCancellationShield { try await self.client.chunkedUploads.createFileUploadSessionForExistingFile(fileId: existingItem.identifier, requestBody: requestBody) }
			return try await uploadLargeFile(for: uploadSession, from: localURL, to: cloudPath, fileSize: fileSize)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: uploadLargeExistingFile(for: \(existingItem.identifier), to: \(cloudPath), fileSize: \(fileSize)) failed with error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func uploadLargeFile(for uploadSession: UploadSession, from localURL: URL, to cloudPath: CloudPath, fileSize: Int) async throws -> CloudItemMetadata {
		guard let uploadPartUrl = uploadSession.sessionEndpoints?.uploadPart, let commitUrl = uploadSession.sessionEndpoints?.commit, let partSize = uploadSession.partSize else {
			throw BoxSDKError(message: "Failed to retrieve upload session data")
		}
		// Parts are uploaded one by one instead of through the SDK's reducer, which would keep a second copy of each part in memory.
		var fileHash = Insecure.SHA1()
		var parts = [UploadPart]()
		var offset: Int64 = 0
		let fileHandle = try FileHandle(forReadingFrom: localURL)
		defer {
			try? fileHandle.close()
		}
		while let chunk = try fileHandle.read(upToCount: Int(partSize)), !chunk.isEmpty {
			try _Concurrency.Task.checkCancellation()
			let digest = "sha=\(Data(Insecure.SHA1.hash(data: chunk)).base64EncodedString())"
			let contentRange = "bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(fileSize)"
			let uploadedPart = try await withBoxSDKCancellationShield { try await self.client.chunkedUploads.uploadFilePartByUrl(url: uploadPartUrl, requestBody: InputStream(data: chunk), headers: UploadFilePartByUrlHeaders(digest: digest, contentRange: contentRange)) }
			guard let part = uploadedPart.part else {
				throw BoxSDKError(message: "Failed to retrieve uploaded part")
			}
			parts.append(part)
			fileHash.update(data: chunk)
			offset += Int64(chunk.count)
		}
		let digest = "sha=\(Data(fileHash.finalize()).base64EncodedString())"
		try _Concurrency.Task.checkCancellation()
		let committedSession = try await withBoxSDKCancellationShield { [parts] in try await self.client.chunkedUploads.createFileUploadSessionCommitByUrl(url: commitUrl, requestBody: CreateFileUploadSessionCommitByUrlRequestBody(parts: parts), headers: CreateFileUploadSessionCommitByUrlHeaders(digest: digest)) }
		guard let file = committedSession?.entries?.first else {
			throw CloudProviderError.itemNotFound
		}
		CloudAccessDDLogDebug("BoxCloudProvider: uploadLargeFile(for: \(uploadSession), to: \(cloudPath), fileSize: \(fileSize)) received file: \((try? file.serializeToString()) ?? file)")
		return convertToCloudItemMetadata(file, at: cloudPath)
	}

	private func createFolder(for parentItem: BoxItem, with name: String) async throws {
		do {
			let requestBody = CreateFolderRequestBody(name: name, parent: CreateFolderRequestBodyParentField(id: parentItem.identifier))
			let folder = try await withBoxSDKCancellationShield { try await self.client.folders.createFolder(requestBody: requestBody) }
			CloudAccessDDLogDebug("BoxCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) received folder: \((try? folder.serializeToString()) ?? folder)")
			let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
			let item = BoxItem(cloudPath: cloudPath, folder: folder)
			try identifierCache.addOrUpdate(item)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) failed with error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func deleteFile(for item: BoxItem) async throws {
		CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) called")
		guard item.itemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		do {
			try await withBoxSDKCancellationShield { try await self.client.files.deleteFileById(fileId: item.identifier) }
			CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) succeeded")
			try identifierCache.invalidate(item)
		} catch let error as BoxAPIError where error.responseInfo.statusCode == 404 {
			throw CloudProviderError.itemNotFound
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) failed with error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func deleteFolder(for item: BoxItem) async throws {
		CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) called")
		guard item.itemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
		do {
			let queryParams = DeleteFolderByIdQueryParams(recursive: true)
			try await withBoxSDKCancellationShield { try await self.client.folders.deleteFolderById(folderId: item.identifier, queryParams: queryParams) }
			CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) succeeded")
			try identifierCache.invalidate(item)
		} catch let error as BoxAPIError where error.responseInfo.statusCode == 404 {
			throw CloudProviderError.itemNotFound
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) failed with error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func moveFile(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) async throws {
		CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		do {
			let requestBody = UpdateFileByIdRequestBody(
				name: targetCloudPath.lastPathComponent,
				parent: UpdateFileByIdRequestBodyParentField(id: targetParentItem.identifier)
			)
			let file = try await withBoxSDKCancellationShield { try await self.client.files.updateFileById(fileId: sourceItem.identifier, requestBody: requestBody) }
			CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received file: \((try? file.serializeToString()) ?? file)")
			try identifierCache.invalidate(sourceItem)
			let targetItem = BoxItem(cloudPath: targetCloudPath, file: file)
			try identifierCache.addOrUpdate(targetItem)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) failed with error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	private func moveFolder(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) async throws {
		CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")
		do {
			let requestBody = UpdateFolderByIdRequestBody(
				name: targetCloudPath.lastPathComponent,
				parent: UpdateFolderByIdRequestBodyParentField(id: targetParentItem.identifier)
			)
			let folder = try await withBoxSDKCancellationShield { try await self.client.folders.updateFolderById(folderId: sourceItem.identifier, requestBody: requestBody) }
			CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received folder: \((try? folder.serializeToString()) ?? folder)")
			try identifierCache.invalidate(sourceItem)
			let newItem = BoxItem(cloudPath: targetCloudPath, folder: folder)
			try identifierCache.addOrUpdate(newItem)
		} catch {
			CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) failed with error: \(error.localizedDescription)")
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
			try _Concurrency.Task.checkCancellation()
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
			CloudAccessDDLogDebug("BoxCloudProvider: getBoxItem(for: \(name), withParentItem: \(parentItem.identifier)) failed with error: \(error.localizedDescription)")
			throw convertStandardError(error)
		}
	}

	func findBoxItem(in parentItem: BoxItem, withName name: String, marker: String?) async throws -> BoxItem {
		let queryParams = GetFolderItemsQueryParams(fields: ["name", "size", "modified_at"], usemarker: true, marker: marker, limit: Int64(maxPageSize))
		let items = try await withBoxSDKCancellationShield { try await self.client.folders.getFolderItems(folderId: parentItem.identifier, queryParams: queryParams) }
		CloudAccessDDLogDebug("BoxCloudProvider: findBoxItem(in: \(name), withName: \(name), marker: \(marker ?? "nil")) received items: \((try? items.serializeToString()) ?? items)")
		if let foundItem = try await locateBoxItem(in: items, withName: name, parentItem: parentItem) {
			return foundItem
		} else if let nextMarker = items.nextMarker {
			try _Concurrency.Task.checkCancellation()
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

	private func createInputStream(for localURL: URL) throws -> InputStream {
		guard let inputStream = InputStream(url: localURL) else {
			throw CloudProviderError.itemNotFound
		}
		return inputStream
	}

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
		if isNetworkConnectionError(error) {
			return CloudProviderError.noInternetConnection
		}
		switch error {
		case let error as BoxAPIError where (error.responseInfo.statusCode == 400 && error.responseInfo.rawBody?.contains("invalid_grant") == true) || error.responseInfo.statusCode == 401 || error.responseInfo.statusCode == 403:
			return CloudProviderError.unauthorized
		case let error as BoxAPIError where error.responseInfo.statusCode == 404:
			return CloudProviderError.itemNotFound
		default:
			return error
		}
	}
}
