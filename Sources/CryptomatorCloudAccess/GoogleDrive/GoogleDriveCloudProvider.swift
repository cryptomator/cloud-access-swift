//
//  GoogleDriveCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 24.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AppAuthCore
import Foundation
@preconcurrency import GoogleAPIClientForREST_Drive
import GRDB
@preconcurrency import GTMSessionFetcherCore

/// Safe to share across threads, because `GTLRDriveService` and its fetchers may be used from any thread and the provider only configures the service during initialization.
public final class GoogleDriveCloudProvider: CloudProvider {
	private static let maximumUploadFetcherChunkSize: UInt = 3 * 1024 * 1024 // 3MiB per chunk as GTMSessionFetcher loads the chunk to the memory and the FileProviderExtension has a total memory limit of 15MB

	private let driveService: GTLRDriveService
	private let identifierCache: GoogleDriveIdentifierCache
	private let maxPageSize: Int

	init(credential: GoogleDriveCredential, maxPageSize: Int = .max, urlSessionConfiguration: URLSessionConfiguration) throws {
		self.driveService = credential.driveService
		self.identifierCache = try GoogleDriveIdentifierCache()
		let maxAllowedItemLimit = 1000
		self.maxPageSize = min(max(1, maxPageSize), maxAllowedItemLimit)
		try setupDriveService(credential: credential, configuration: urlSessionConfiguration)
	}

	public convenience init(credential: GoogleDriveCredential, maxPageSize: Int = .max) throws {
		try self.init(credential: credential, maxPageSize: maxPageSize, urlSessionConfiguration: .default)
	}

	public static func withBackgroundSession(credential: GoogleDriveCredential, maxPageSize: Int = .max, sessionIdentifier: String) throws -> GoogleDriveCloudProvider {
		let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
		configuration.sharedContainerIdentifier = GoogleDriveSetup.constants.sharedContainerIdentifier
		return try .init(credential: credential, maxPageSize: maxPageSize, urlSessionConfiguration: configuration)
	}

	private func setupDriveService(credential: GoogleDriveCredential, configuration: URLSessionConfiguration) throws {
		driveService.serviceUploadChunkSize = GoogleDriveCloudProvider.maximumUploadFetcherChunkSize
		driveService.isRetryEnabled = true
		driveService.retryBlock = { _, suggestedWillRetry, fetchError in
			if let fetchError = fetchError as NSError? {
				if fetchError.domain != kGTMSessionFetcherStatusDomain || fetchError.code != 403 {
					return suggestedWillRetry
				}
				guard let data = fetchError.userInfo["data"] as? Data, let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any], let error = json["error"] as? [String: Any] else {
					return suggestedWillRetry
				}
				let googleDriveError = GTLRErrorObject(json: error)
				guard let errorItem = googleDriveError.errors?.first else {
					return suggestedWillRetry
				}
				return errorItem.domain == "usageLimits" && (errorItem.reason == "userRateLimitExceeded" || errorItem.reason == "rateLimitExceeded")
			}
			return suggestedWillRetry
		}

		driveService.fetcherService.configurationBlock = { _, configurationToConfigure in
			configurationToConfigure.sharedContainerIdentifier = configuration.sharedContainerIdentifier
		}
		driveService.fetcherService.configuration = configuration

		driveService.fetcherService.isRetryEnabled = true
		driveService.fetcherService.retryBlock = { suggestedWillRetry, error, response in
			if let error = error as NSError? {
				if error.domain == kGTMSessionFetcherStatusDomain, error.code == 403 {
					return response(true)
				}
			}
			response(suggestedWillRetry)
		}
		driveService.fetcherService.unusedSessionTimeout = 0
		driveService.fetcherService.reuseSession = true
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
		let metadata = try await uploadFile(for: parentItem, from: localURL, to: cloudPath, replaceExisting: replaceExisting, progress: phases[0])
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
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: fetchItemMetadata(for: \(item.identifier)) called")
		let query = fetchItemMetadataQuery(for: item)
		return try await executeQuery(query) { result -> CloudItemMetadata in
			CloudAccessDDLogDebug("GoogleDriveCloudProvider: fetchItemMetadata(for: \(item.identifier)) received result: \((result as? GTLRObject)?.jsonString() ?? result)")
			guard let file = result as? GTLRDrive_File else {
				throw GoogleDriveError.unexpectedResultType
			}
			try self.identifierCache.addOrUpdate(item)
			return self.convertToCloudItemMetadata(file, at: item.cloudPath)
		}
	}

	private func fetchItemList(for item: GoogleDriveItem, pageToken: String?) async throws -> CloudItemList {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: fetchItemList(for: \(item.identifier), pageToken: \(pageToken ?? "nil")) called")
		guard item.itemType == .folder || (item.itemType == .symlink && item.shortcut?.targetItemType == .folder) else {
			throw CloudProviderError.itemTypeMismatch
		}
		let query = fetchItemListQuery(for: item, pageToken: pageToken)
		do {
			let (children, nextPageToken) = try await executeQuery(query) { result -> ([(item: GoogleDriveItem, metadata: CloudItemMetadata)], String?) in
				CloudAccessDDLogDebug("GoogleDriveCloudProvider: fetchItemList(for: \(item.identifier), pageToken: \(pageToken ?? "nil")) received result: \((result as? GTLRObject)?.jsonString() ?? result)")
				guard let fileList = result as? GTLRDrive_FileList else {
					throw GoogleDriveError.unexpectedResultType
				}
				var children = [(item: GoogleDriveItem, metadata: CloudItemMetadata)]()
				for file in fileList.files ?? [GTLRDrive_File]() {
					guard let name = file.name else {
						throw GoogleDriveError.missingItemName
					}
					let cloudPath = item.cloudPath.appendingPathComponent(name)
					try children.append((GoogleDriveItem(cloudPath: cloudPath, file: file), self.convertToCloudItemMetadata(file, at: cloudPath)))
				}
				return (children, fileList.nextPageToken)
			}
			var items = [CloudItemMetadata]()
			for child in children {
				try identifierCache.addOrUpdate(child.item)
				guard let shortcut = child.item.shortcut else {
					items.append(child.metadata)
					continue
				}
				try Task.checkCancellation()
				do {
					try await items.append(resolveShortcut(shortcut, at: child.item.cloudPath))
				} catch let error as CancellationError {
					throw error
				} catch {
					continue
				}
			}
			return CloudItemList(items: items, nextPageToken: nextPageToken)
		} catch {
			if let error = error as NSError?, error.domain == kGTLRErrorObjectDomain, error.code == 400 {
				throw CloudProviderError.pageTokenInvalid
			}
			throw error
		}
	}

	private func downloadFile(for item: GoogleDriveItem, to localURL: URL, progress: Progress?) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) called")
		guard item.itemType == .file || (item.itemType == .symlink && item.shortcut?.targetItemType == .file) else {
			throw CloudProviderError.itemTypeMismatch
		}
		let remoteMetadata = try await fetchItemMetadata(for: item)
		try Task.checkCancellation()
		return try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			let query = downloadFileQuery(for: item)
			let request = await driveService.request(for: query)
			let fetcher = driveService.fetcherService.fetcher(with: request as URLRequest)
			fetcher.destinationFileURL = stagedFile
			fetcher.downloadProgressBlock = { _, totalBytesWritten, totalBytesExpectedToWrite in
				progress?.totalUnitCount = totalBytesExpectedToWrite // Unnecessary to set several times
				progress?.completedUnitCount = totalBytesWritten
			}
			try await executeFetcher(fetcher)
			return remoteMetadata
		})
	}

	private func uploadFile(for parentItem: GoogleDriveItem, from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path)) called")
		let query = try await uploadFileQuery(for: parentItem, from: localURL, to: cloudPath, replaceExisting: replaceExisting)
		query.executionParameters.uploadProgressBlock = { _, totalBytesUploaded, totalBytesExpectedToUpload in
			progress?.totalUnitCount = Int64(totalBytesExpectedToUpload)
			progress?.completedUnitCount = Int64(totalBytesUploaded)
		}
		try Task.checkCancellation()
		return try await executeQuery(query) { result -> CloudItemMetadata in
			CloudAccessDDLogDebug("GoogleDriveCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path)) received result: \((result as? GTLRObject)?.jsonString() ?? result)")
			guard let uploadedFile = result as? GTLRDrive_File else {
				throw GoogleDriveError.unexpectedResultType
			}
			let item = try GoogleDriveItem(cloudPath: cloudPath, file: uploadedFile)
			try self.identifierCache.addOrUpdate(item)
			return self.convertToCloudItemMetadata(uploadedFile, at: cloudPath)
		}
	}

	private func createFolder(for parentItem: GoogleDriveItem, with name: String) async throws {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) called")
		let query = createFolderQuery(for: parentItem, with: name)
		try await executeQuery(query) { result -> Void in
			CloudAccessDDLogDebug("GoogleDriveCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) received result: \((result as? GTLRObject)?.jsonString() ?? result)")
			guard let folder = result as? GTLRDrive_File else {
				throw GoogleDriveError.unexpectedResultType
			}
			let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
			let item = try GoogleDriveItem(cloudPath: cloudPath, file: folder)
			try self.identifierCache.addOrUpdate(item)
		}
	}

	private func deleteItem(for item: GoogleDriveItem) async throws {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: deleteItem(for: \(item.identifier)) called")
		let query = deleteItemQuery(for: item)
		try await executeQuery(query) { result -> Void in
			CloudAccessDDLogDebug("GoogleDriveCloudProvider: deleteItem(for: \(item.identifier)) received result: \((result as? GTLRObject)?.jsonString() ?? result)")
			guard result is Void else {
				throw GoogleDriveError.unexpectedResultType
			}
			try self.identifierCache.invalidate(item)
		}
	}

	private func moveItem(for sourceItem: GoogleDriveItem, from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: moveItem(for: \(sourceItem.identifier), from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) called")
		let query = try await moveItemQuery(for: sourceItem, from: sourceCloudPath, to: targetCloudPath)
		try Task.checkCancellation()
		try await executeQuery(query) { result -> Void in
			CloudAccessDDLogDebug("GoogleDriveCloudProvider: moveItem(for: \(sourceItem.identifier), from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) received result: \((result as? GTLRObject)?.jsonString() ?? result)")
			guard let file = result as? GTLRDrive_File else {
				throw GoogleDriveError.unexpectedResultType
			}
			try self.identifierCache.invalidate(sourceItem)
			let targetItem = try GoogleDriveItem(cloudPath: targetCloudPath, file: file)
			try self.identifierCache.addOrUpdate(targetItem)
		}
	}

	// MARK: - Resolve Path

	private func resolvePath(forItemAt cloudPath: CloudPath) async throws -> GoogleDriveItem {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: resolvePath(forItemAt: \(cloudPath.path)) called")
		var pathToCheckForCache = cloudPath
		var cachedItem = identifierCache.get(pathToCheckForCache)
		while cachedItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
			pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
			cachedItem = identifierCache.get(pathToCheckForCache)
		}
		guard let item = cachedItem else {
			throw GoogleDriveError.inconsistentCache
		}
		if pathToCheckForCache != cloudPath {
			return try await traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: item)
		}
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: resolvePath(forItemAt: \(cloudPath.path)) finished with item: \(item.identifier)")
		return item
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) async throws -> GoogleDriveItem {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		do {
			return try await resolvePath(forItemAt: parentCloudPath)
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}

	/**
	 Traverses from `startCloudPath` to `endCloudPath` using the identifier that belongs to `startCloudPath`.

	 This is necessary because Google Drive does not use normal paths, but only works with (parent-)identifiers.

	 To save on future requests, every intermediate path is also cached.

	 - Precondition: The `startCloudPath` is an actual subpath of `endCloudPath`.
	 - Postcondition: Each identifier belonging to the respective intermediate path or `endCloudPath` is cached in the `identifierCache`.
	 - Parameter startCloudPath: The cloud path of the folder from which the traversal is started.
	 - Parameter endCloudPath: The cloud path of the item, which is the actual target and from which the Google Drive item is returned at the end.
	 - Parameter startItem: The Google Drive item to which `startCloudPath` points.
	 - Returns: The Google Drive item that belongs to `endCloudPath`.
	 */
	private func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: GoogleDriveItem) async throws -> GoogleDriveItem {
		assert(startCloudPath.pathComponents.count < endCloudPath.pathComponents.count)
		let startIndex = startCloudPath.pathComponents.count
		let endIndex = endCloudPath.pathComponents.count
		var parentItem = startItem
		for i in startIndex ..< endIndex {
			let name = endCloudPath.pathComponents[i]
			try Task.checkCancellation()
			parentItem = try await getGoogleDriveItem(name: name, parentItem: parentItem)
			try identifierCache.addOrUpdate(parentItem)
		}
		return parentItem
	}

	/**
	 Searches the folder belonging to `parentItem.identifier` for an item with the same `name`.

	 This is necessary because Google Drive does not use normal paths, but only works with (parent-)identifiers.

	 Shortcuts are supported by resolving them transparently to the target.

	 Workaround for cyrillic names: https://stackoverflow.com/a/47282129/1759462
	 */
	private func getGoogleDriveItem(name: String, parentItem: GoogleDriveItem) async throws -> GoogleDriveItem {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: getGoogleDriveItem(name: \(name), parentItem: \(parentItem.identifier)) called")
		let resolvedParentItemIdentifier = parentItem.shortcut?.targetIdentifier ?? parentItem.identifier
		let query = GTLRDriveQuery_FilesList.query()
		query.supportsAllDrives = true
		query.includeItemsFromAllDrives = true
		query.q = "'\(resolvedParentItemIdentifier)' in parents and name contains '\(escapedQueryValue(name))' and trashed = false"
		query.fields = "files(id,name,mimeType,shortcutDetails)"
		return try await executeQuery(query) { result -> GoogleDriveItem in
			CloudAccessDDLogDebug("GoogleDriveCloudProvider: getGoogleDriveItem(name: \(name), parentItem: \(parentItem.identifier)) received result: \((result as? GTLRObject)?.jsonString() ?? result)")
			if let fileList = result as? GTLRDrive_FileList {
				for file in fileList.files ?? [GTLRDrive_File]() where file.name == name {
					return try GoogleDriveItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), file: file)
				}
				throw CloudProviderError.itemNotFound
			} else {
				throw GoogleDriveError.unexpectedResultType
			}
		}
	}

	// MARK: - Resolve Shortcut

	private func resolveShortcut(_ shortcut: GoogleDriveShortcut, at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("GoogleDriveCloudProvider: resolveShortcut(\(shortcut.targetIdentifier), at: \(cloudPath.path)) called")
		let query = GTLRDriveQuery_FilesGet.query(withFileId: shortcut.targetIdentifier)
		query.supportsAllDrives = true
		query.fields = "modifiedTime,size,mimeType"
		return try await executeQuery(query) { result -> CloudItemMetadata in
			CloudAccessDDLogDebug("GoogleDriveCloudProvider: resolveShortcut(\(shortcut.targetIdentifier), at: \(cloudPath.path)) received result: \((result as? GTLRObject)?.jsonString() ?? result)")
			guard let file = result as? GTLRDrive_File else {
				throw GoogleDriveError.unexpectedResultType
			}
			return self.convertToCloudItemMetadata(file, at: cloudPath)
		}
	}

	// MARK: - Queries

	private func fetchItemMetadataQuery(for item: GoogleDriveItem) -> GTLRDriveQuery {
		let resolvedIdentifier = item.shortcut?.targetIdentifier ?? item.identifier
		let query = GTLRDriveQuery_FilesGet.query(withFileId: resolvedIdentifier)
		query.supportsAllDrives = true
		query.fields = "name,modifiedTime,size,mimeType"
		return query
	}

	private func fetchItemListQuery(for item: GoogleDriveItem, pageToken: String?) -> GTLRDriveQuery {
		let resolvedIdentifier = item.shortcut?.targetIdentifier ?? item.identifier
		let query = GTLRDriveQuery_FilesList.query()
		query.supportsAllDrives = true
		query.includeItemsFromAllDrives = true
		query.q = "'\(resolvedIdentifier)' in parents and trashed = false"
		query.pageSize = maxPageSize
		query.pageToken = pageToken
		query.fields = "nextPageToken,files(id,name,modifiedTime,size,mimeType,shortcutDetails)"
		return query
	}

	private func downloadFileQuery(for item: GoogleDriveItem) -> GTLRDriveQuery {
		let resolvedIdentifier = item.shortcut?.targetIdentifier ?? item.identifier
		let query = GTLRDriveQuery_FilesGet.queryForMedia(withFileId: resolvedIdentifier)
		query.supportsAllDrives = true
		return query
	}

	private func uploadFileQuery(for parentItem: GoogleDriveItem, from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) async throws -> GTLRDriveQuery {
		let resolvedParentIdentifier = parentItem.shortcut?.targetIdentifier ?? parentItem.identifier
		let metadata = GTLRDrive_File()
		metadata.name = cloudPath.lastPathComponent
		let uploadParameters = GTLRUploadParameters(fileURL: localURL, mimeType: "application/octet-stream")
		let uploadQuery: GTLRDriveQuery
		do {
			let item = try await resolvePath(forItemAt: cloudPath)
			if !replaceExisting || (replaceExisting && item.itemType == .folder) {
				throw CloudProviderError.itemAlreadyExists
			}
			let query = GTLRDriveQuery_FilesUpdate.query(withObject: metadata, fileId: item.identifier, uploadParameters: uploadParameters)
			query.supportsAllDrives = true
			uploadQuery = query
		} catch CloudProviderError.itemNotFound {
			metadata.parents = [resolvedParentIdentifier]
			let query = GTLRDriveQuery_FilesCreate.query(withObject: metadata, uploadParameters: uploadParameters)
			query.supportsAllDrives = true
			uploadQuery = query
		}
		uploadQuery.fields = "id,name,modifiedTime,size,mimeType"
		return uploadQuery
	}

	private func createFolderQuery(for parentItem: GoogleDriveItem, with name: String) -> GTLRDriveQuery {
		let resolvedParentIdentifier = parentItem.shortcut?.targetIdentifier ?? parentItem.identifier
		let metadata = GTLRDrive_File()
		metadata.name = name
		metadata.parents = [resolvedParentIdentifier]
		metadata.mimeType = "application/vnd.google-apps.folder"
		let query = GTLRDriveQuery_FilesCreate.query(withObject: metadata, uploadParameters: nil)
		query.supportsAllDrives = true
		return query
	}

	private func deleteItemQuery(for item: GoogleDriveItem) -> GTLRDriveQuery {
		// do not resolve to the shortcut's target since the shortcut itself should be deleted
		let query = GTLRDriveQuery_FilesDelete.query(withFileId: item.identifier)
		query.supportsAllDrives = true
		return query
	}

	private func moveItemQuery(for item: GoogleDriveItem, from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws -> GTLRDriveQuery {
		// do not resolve the source to the shortcut's target since the shortcut itself should be moved
		let metadata = GTLRDrive_File()
		metadata.name = targetCloudPath.lastPathComponent
		let query = GTLRDriveQuery_FilesUpdate.query(withObject: metadata, fileId: item.identifier, uploadParameters: nil)
		query.supportsAllDrives = true
		query.fields = "id,modifiedTime"
		if onlyItemNameChangedBetween(sourceCloudPath, and: targetCloudPath) {
			return query
		} else {
			let oldParentItem = try await resolveParentPath(forItemAt: sourceCloudPath)
			let newParentItem = try await resolveParentPath(forItemAt: targetCloudPath)
			// but resolve the target's parent if it is a shortcut
			let resolvedNewParentIdentifier = newParentItem.shortcut?.targetIdentifier ?? newParentItem.identifier
			query.addParents = resolvedNewParentIdentifier
			query.removeParents = oldParentItem.identifier
			return query
		}
	}

	// MARK: - Execution

	private func executeQuery<Value: Sendable>(_ query: GTLRDriveQuery, convert: @escaping (Any) throws -> Value) async throws -> Value {
		return try await withSDKContinuation { resumer in
			driveService.executeQuery(query) { _, result, error in
				if let error = error as NSError? {
					CloudAccessDDLogDebug("GoogleDriveCloudProvider: executeQuery(\(query.requestID)) failed with error: \(error)")
					resumer.resume(throwing: self.convertQueryError(error))
					return
				}
				do {
					try resumer.resume(returning: convert(result ?? ()))
				} catch {
					resumer.resume(throwing: error)
				}
			}
		}
	}

	private func executeFetcher(_ fetcher: GTMSessionFetcher) async throws {
		try await withSDKContinuation { (resumer: Resumer<Void>) in
			fetcher.beginFetch { _, error in
				if let error = error as NSError? {
					CloudAccessDDLogDebug("GoogleDriveCloudProvider: executeFetcher(\(fetcher.request?.description ?? "nil")) failed with error: \(error)")
					resumer.resume(throwing: self.convertFetcherError(error))
					return
				}
				resumer.resume()
			}
		}
	}

	// MARK: - Helpers

	private func convertToCloudItemMetadata(_ file: GTLRDrive_File, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = cloudPath.lastPathComponent
		let itemType = file.getCloudItemType()
		let lastModifiedDate = file.modifiedTime?.date
		let size = file.size?.intValue
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
	}

	func convertQueryError(_ error: NSError) -> Error {
		if isCancellationError(error) {
			return CancellationError()
		} else if isNetworkConnectionError(error) {
			return CloudProviderError.noInternetConnection
		} else if (error.domain == kGTLRErrorObjectDomain && (error.code == 401 || error.code == 403)) || (error.domain == OIDOAuthTokenErrorDomain && error.code == OIDErrorCodeOAuth.invalidGrant.rawValue) {
			return CloudProviderError.unauthorized
		} else if error.domain == kGTLRErrorObjectDomain, error.code == 404 {
			return CloudProviderError.itemNotFound
		} else if error.domain == kGTLRErrorObjectDomain, error.code == 507 {
			// This has never been verified and Google Drive API documentation is sparse.
			return CloudProviderError.quotaInsufficient
		} else {
			return error
		}
	}

	func convertFetcherError(_ error: NSError) -> Error {
		if isCancellationError(error) {
			return CancellationError()
		} else if isNetworkConnectionError(error) {
			return CloudProviderError.noInternetConnection
		} else if error.domain == kGTMSessionFetcherStatusDomain, error.code == 401 || error.code == 403 {
			return CloudProviderError.unauthorized
		} else if error.domain == kGTMSessionFetcherStatusDomain, error.code == 404 {
			return CloudProviderError.itemNotFound
		} else {
			return error
		}
	}

	func onlyItemNameChangedBetween(_ lhs: CloudPath, and rhs: CloudPath) -> Bool {
		let lhsWithoutItemName = lhs.deletingLastPathComponent()
		let rhsWithoutItemName = rhs.deletingLastPathComponent()
		return lhsWithoutItemName == rhsWithoutItemName
	}

	func escapedQueryValue(_ value: String) -> String {
		return value.replacingOccurrences(of: "'", with: "\\'")
	}
}
