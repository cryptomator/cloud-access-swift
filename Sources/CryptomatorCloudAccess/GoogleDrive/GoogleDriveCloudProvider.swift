//
//  GoogleDriveCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 24.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GoogleAPIClientForREST_Drive
import GRDB
import GTMSessionFetcherCore
import Promises

public class GoogleDriveCloudProvider: CloudProvider {
	private static let maximumUploadFetcherChunkSize: UInt = 3 * 1024 * 1024 // 3MiB per chunk as GTMSessionFetcher loads the chunk to the memory and the FileProviderExtension has a total memory limit of 15MB

	private let driveService: GTLRDriveService
	private let identifierCache: GoogleDriveIdentifierCache

	private var runningTickets: [GTLRServiceTicket]
	private var runningFetchers: [GTMSessionFetcher]

	public init(credential: GoogleDriveCredential, useBackgroundSession: Bool = false) throws {
		self.driveService = credential.driveService
		self.identifierCache = try GoogleDriveIdentifierCache()
		self.runningTickets = [GTLRServiceTicket]()
		self.runningFetchers = [GTMSessionFetcher]()
		try setupDriveService(credential: credential, useBackgroundSession: useBackgroundSession)
	}

	private func setupDriveService(credential: GoogleDriveCredential, useBackgroundSession: Bool) throws {
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

		let configuration: URLSessionConfiguration
		if useBackgroundSession {
			driveService.fetcherService.configurationBlock = { _, configuration in
				configuration.sharedContainerIdentifier = GoogleDriveSetup.constants.sharedContainerIdentifier
			}
			let bundleId = Bundle.main.bundleIdentifier ?? ""
			configuration = URLSessionConfiguration.background(withIdentifier: "Crytomator-GoogleDriveSession-\(try credential.getAccountID())-\(bundleId)")
			configuration.sharedContainerIdentifier = GoogleDriveSetup.constants.sharedContainerIdentifier
		} else {
			configuration = URLSessionConfiguration.default
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

	deinit {
		for ticket in runningTickets {
			ticket.cancel()
		}
		for fetcher in runningFetchers {
			fetcher.stopFetching()
		}
	}

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		return resolvePath(forItemAt: cloudPath).then { item in
			return self.fetchItemMetadata(for: item)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		return resolvePath(forItemAt: cloudPath).then { item in
			return self.fetchItemList(for: item, pageToken: pageToken)
		}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		if FileManager.default.fileExists(atPath: localURL.path) {
			return Promise(CloudProviderError.itemAlreadyExists)
		}
		let progress = Progress(totalUnitCount: 1)
		return resolvePath(forItemAt: cloudPath).then { item -> Promise<Void> in
			progress.becomeCurrent(withPendingUnitCount: 1)
			let downloadPromise = self.downloadFile(for: item, to: localURL)
			progress.resignCurrent()
			return downloadPromise
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
		let progress = Progress(totalUnitCount: 1)
		return resolveParentPath(forItemAt: cloudPath).then { parentItem in
			progress.becomeCurrent(withPendingUnitCount: 1)
			let uploadPromise = self.uploadFile(for: parentItem, from: localURL, to: cloudPath, replaceExisting: replaceExisting)
			progress.resignCurrent()
			return uploadPromise
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
		return deleteItem(at: cloudPath)
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath)
	}

	private func deleteItem(at cloudPath: CloudPath) -> Promise<Void> {
		return resolvePath(forItemAt: cloudPath).then { item in
			return self.deleteItem(for: item)
		}
	}

	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: targetCloudPath).then { itemExists -> Void in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then {
			return self.resolvePath(forItemAt: sourceCloudPath)
		}.then { item in
			return self.moveItem(for: item, from: sourceCloudPath, to: targetCloudPath)
		}
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: GoogleDriveItem) -> Promise<CloudItemMetadata> {
		let query = fetchItemMetadataQuery(for: item)
		return executeQuery(query).then { result -> CloudItemMetadata in
			guard let file = result as? GTLRDrive_File else {
				throw GoogleDriveError.unexpectedResultType
			}
			try self.identifierCache.addOrUpdate(item)
			return try self.convertToCloudItemMetadata(file, at: item.cloudPath)
		}
	}

	private func fetchItemList(for item: GoogleDriveItem, pageToken: String?) -> Promise<CloudItemList> {
		guard item.itemType == .folder || (item.itemType == .symlink && item.shortcut?.targetItemType == .folder) else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		let query = fetchItemListQuery(for: item, pageToken: pageToken)
		return executeQuery(query).then(on: .global()) { result -> CloudItemList in
			guard let fileList = result as? GTLRDrive_FileList else {
				throw GoogleDriveError.unexpectedResultType
			}
			var items = [CloudItemMetadata]()
			try fileList.files?.forEach { file in
				guard let name = file.name else {
					throw GoogleDriveError.missingItemName
				}
				let cloudPath = item.cloudPath.appendingPathComponent(name)
				let item = try GoogleDriveItem(cloudPath: cloudPath, file: file)
				try self.identifierCache.addOrUpdate(item)
				let resolvedFile = try awaitPromise(self.resolveFile(file, with: item))
				let itemMetadata = try self.convertToCloudItemMetadata(resolvedFile, at: cloudPath)
				items.append(itemMetadata)
			}
			return CloudItemList(items: items, nextPageToken: fileList.nextPageToken)
		}.recover { error -> CloudItemList in
			if let error = error as NSError?, error.domain == kGTLRErrorObjectDomain, error.code == 400 {
				throw CloudProviderError.pageTokenInvalid
			}
			throw error
		}
	}

	private func downloadFile(for item: GoogleDriveItem, to localURL: URL) -> Promise<Void> {
		guard item.itemType == .file || (item.itemType == .symlink && item.shortcut?.targetItemType == .file) else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		let query = downloadFileQuery(for: item)
		let request = driveService.request(for: query)
		let fetcher = driveService.fetcherService.fetcher(with: request as URLRequest)
		fetcher.destinationFileURL = localURL
		let progress = Progress(totalUnitCount: -1)
		fetcher.downloadProgressBlock = { _, totalBytesWritten, totalBytesExpectedToWrite in
			progress.totalUnitCount = totalBytesExpectedToWrite // Unnecessary to set several times
			progress.completedUnitCount = totalBytesWritten
		}
		return executeFetcher(fetcher)
	}

	private func uploadFile(for parentItem: GoogleDriveItem, from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		let progress = Progress(totalUnitCount: -1)
		return uploadFileQuery(for: parentItem, from: localURL, to: cloudPath, replaceExisting: replaceExisting).then { query -> Promise<Any> in
			query.executionParameters.uploadProgressBlock = { _, totalBytesUploaded, totalBytesExpectedToUpload in
				progress.totalUnitCount = Int64(totalBytesExpectedToUpload)
				progress.completedUnitCount = Int64(totalBytesUploaded)
			}
			return self.executeQuery(query)
		}.then { result -> CloudItemMetadata in
			guard let uploadedFile = result as? GTLRDrive_File else {
				throw GoogleDriveError.unexpectedResultType
			}
			let item = try GoogleDriveItem(cloudPath: cloudPath, file: uploadedFile)
			try self.identifierCache.addOrUpdate(item)
			return try self.convertToCloudItemMetadata(uploadedFile, at: cloudPath)
		}
	}

	private func createFolder(for parentItem: GoogleDriveItem, with name: String) -> Promise<Void> {
		let query = createFolderQuery(for: parentItem, with: name)
		return executeQuery(query).then { result -> Void in
			guard let folder = result as? GTLRDrive_File else {
				throw GoogleDriveError.unexpectedResultType
			}
			let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
			let item = try GoogleDriveItem(cloudPath: cloudPath, file: folder)
			try self.identifierCache.addOrUpdate(item)
		}
	}

	private func deleteItem(for item: GoogleDriveItem) -> Promise<Void> {
		let query = deleteItemQuery(for: item)
		return executeQuery(query).then { result -> Void in
			guard result is Void else {
				throw GoogleDriveError.unexpectedResultType
			}
			try self.identifierCache.invalidate(item)
		}
	}

	private func moveItem(for sourceItem: GoogleDriveItem, from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItemQuery(for: sourceItem, from: sourceCloudPath, to: targetCloudPath).then { query in
			self.executeQuery(query)
		}.then { result -> Void in
			guard let file = result as? GTLRDrive_File else {
				throw GoogleDriveError.unexpectedResultType
			}
			try self.identifierCache.invalidate(sourceItem)
			let targetItem = try GoogleDriveItem(cloudPath: targetCloudPath, file: file)
			try self.identifierCache.addOrUpdate(targetItem)
		}
	}

	// MARK: - Resolve Path

	private func resolvePath(forItemAt cloudPath: CloudPath) -> Promise<GoogleDriveItem> {
		var pathToCheckForCache = cloudPath
		var cachedItem = identifierCache.get(pathToCheckForCache)
		while cachedItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
			pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
			cachedItem = identifierCache.get(pathToCheckForCache)
		}
		guard let item = cachedItem else {
			return Promise(GoogleDriveError.inconsistentCache)
		}
		if pathToCheckForCache != cloudPath {
			return traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: item)
		}
		return Promise(item)
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) -> Promise<GoogleDriveItem> {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		return resolvePath(forItemAt: parentCloudPath).recover { error -> GoogleDriveItem in
			if case CloudProviderError.itemNotFound = error {
				throw CloudProviderError.parentFolderDoesNotExist
			} else {
				throw error
			}
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
	 - Returns: Promise is fulfilled with the Google Drive item that belongs to `endCloudPath`.
	 */
	private func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: GoogleDriveItem) -> Promise<GoogleDriveItem> {
		assert(startCloudPath.pathComponents.count < endCloudPath.pathComponents.count)
		let startIndex = startCloudPath.pathComponents.count
		let endIndex = endCloudPath.pathComponents.count
		var currentPath = startCloudPath
		var parentItem = startItem
		return Promise(on: .global()) { fulfill, _ in
			for i in startIndex ..< endIndex {
				let name = endCloudPath.pathComponents[i]
				currentPath = currentPath.appendingPathComponent(name)
				parentItem = try awaitPromise(self.getGoogleDriveItem(name: name, parentItem: parentItem))
				try self.identifierCache.addOrUpdate(parentItem)
			}
			fulfill(parentItem)
		}
	}

	/**
	 Searches the folder belonging to `parentItem.identifier` for an item with the same `name`.

	 This is necessary because Google Drive does not use normal paths, but only works with (parent-)identifiers.

	 Shortcuts are supported by resolving them transparently to the target.

	 Workaround for cyrillic names: https://stackoverflow.com/a/47282129/1759462
	 */
	private func getGoogleDriveItem(name: String, parentItem: GoogleDriveItem) -> Promise<GoogleDriveItem> {
		let resolvedParentItemIdentifier = parentItem.shortcut?.targetIdentifier ?? parentItem.identifier
		let query = GTLRDriveQuery_FilesList.query()
		query.q = "'\(resolvedParentItemIdentifier)' in parents and name contains '\(name)' and trashed = false"
		query.fields = "files(id,name,mimeType,shortcutDetails)"
		return executeQuery(query).then { result -> GoogleDriveItem in
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

	private func resolveFile(_ file: GTLRDrive_File, with item: GoogleDriveItem) -> Promise<GTLRDrive_File> {
		if let shortcut = item.shortcut {
			return resolveShortcut(shortcut, at: item.cloudPath)
		} else {
			return Promise(file)
		}
	}

	private func resolveShortcut(_ shortcut: GoogleDriveShortcut, at cloudPath: CloudPath) -> Promise<GTLRDrive_File> {
		let query = GTLRDriveQuery_FilesGet.query(withFileId: shortcut.targetIdentifier)
		query.fields = "modifiedTime,size,mimeType"
		return executeQuery(query).then { result -> GTLRDrive_File in
			guard let file = result as? GTLRDrive_File else {
				throw GoogleDriveError.unexpectedResultType
			}
			return file
		}
	}

	// MARK: - Queries

	private func fetchItemMetadataQuery(for item: GoogleDriveItem) -> GTLRDriveQuery {
		let resolvedIdentifier = item.shortcut?.targetIdentifier ?? item.identifier
		let query = GTLRDriveQuery_FilesGet.query(withFileId: resolvedIdentifier)
		query.fields = "name,modifiedTime,size,mimeType"
		return query
	}

	private func fetchItemListQuery(for item: GoogleDriveItem, pageToken: String?) -> GTLRDriveQuery {
		let resolvedIdentifier = item.shortcut?.targetIdentifier ?? item.identifier
		let query = GTLRDriveQuery_FilesList.query()
		query.q = "'\(resolvedIdentifier)' in parents and trashed = false"
		query.pageSize = 1000
		query.pageToken = pageToken
		query.fields = "nextPageToken,files(id,name,modifiedTime,size,mimeType,shortcutDetails)"
		return query
	}

	private func downloadFileQuery(for item: GoogleDriveItem) -> GTLRDriveQuery {
		let resolvedIdentifier = item.shortcut?.targetIdentifier ?? item.identifier
		return GTLRDriveQuery_FilesGet.queryForMedia(withFileId: resolvedIdentifier)
	}

	private func uploadFileQuery(for parentItem: GoogleDriveItem, from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<GTLRDriveQuery> {
		let resolvedParentIdentifier = parentItem.shortcut?.targetIdentifier ?? parentItem.identifier
		let metadata = GTLRDrive_File()
		metadata.name = cloudPath.lastPathComponent
		let uploadParameters = GTLRUploadParameters(fileURL: localURL, mimeType: "application/octet-stream")
		return resolvePath(forItemAt: cloudPath).then { item -> Promise<GTLRDriveQuery> in
			if !replaceExisting || (replaceExisting && item.itemType == .folder) {
				return Promise(CloudProviderError.itemAlreadyExists)
			}
			let query = GTLRDriveQuery_FilesUpdate.query(withObject: metadata, fileId: item.identifier, uploadParameters: uploadParameters)
			return Promise(query)
		}.recover { error -> GTLRDriveQuery in
			guard case CloudProviderError.itemNotFound = error else {
				throw error
			}
			metadata.parents = [resolvedParentIdentifier]
			let query = GTLRDriveQuery_FilesCreate.query(withObject: metadata, uploadParameters: uploadParameters)
			return query
		}.then { query -> GTLRDriveQuery in
			query.fields = "id,name,modifiedTime,size,mimeType"
			return query
		}
	}

	private func createFolderQuery(for parentItem: GoogleDriveItem, with name: String) -> GTLRDriveQuery {
		let resolvedParentIdentifier = parentItem.shortcut?.targetIdentifier ?? parentItem.identifier
		let metadata = GTLRDrive_File()
		metadata.name = name
		metadata.parents = [resolvedParentIdentifier]
		metadata.mimeType = "application/vnd.google-apps.folder"
		return GTLRDriveQuery_FilesCreate.query(withObject: metadata, uploadParameters: nil)
	}

	private func deleteItemQuery(for item: GoogleDriveItem) -> GTLRDriveQuery {
		// do not resolve to the shortcut's target since the shortcut itself should be deleted
		return GTLRDriveQuery_FilesDelete.query(withFileId: item.identifier)
	}

	private func moveItemQuery(for item: GoogleDriveItem, from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<GTLRDriveQuery> {
		// do not resolve the source to the shortcut's target since the shortcut itself should be moved
		let metadata = GTLRDrive_File()
		metadata.name = targetCloudPath.lastPathComponent
		let query = GTLRDriveQuery_FilesUpdate.query(withObject: metadata, fileId: item.identifier, uploadParameters: nil)
		query.fields = "id,modifiedTime"
		if onlyItemNameChangedBetween(sourceCloudPath, and: targetCloudPath) {
			return Promise(query)
		} else {
			let sourceParentCloudPath = sourceCloudPath.deletingLastPathComponent()
			let targetParentCloudPath = targetCloudPath.deletingLastPathComponent()
			return all(resolvePath(forItemAt: sourceParentCloudPath), resolvePath(forItemAt: targetParentCloudPath)).then { oldParentItem, newParentItem -> GTLRDriveQuery_FilesUpdate in
				// but resolve the target's parent if it is a shortcut
				let resolvedNewParentIdentifier = newParentItem.shortcut?.targetIdentifier ?? newParentItem.identifier
				query.addParents = resolvedNewParentIdentifier
				query.removeParents = oldParentItem.identifier
				return query
			}
		}
	}

	// MARK: - Execution

	private func executeQuery(_ query: GTLRDriveQuery) -> Promise<Any> {
		return Promise<Any> { fulfill, reject in
			let ticket = self.driveService.executeQuery(query) { ticket, result, error in
				self.runningTickets.removeAll { $0 == ticket }
				if let error = error as NSError? {
					if error.domain == NSURLErrorDomain, error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorCannotConnectToHost || error.code == NSURLErrorNetworkConnectionLost || error.code == NSURLErrorDNSLookupFailed || error.code == NSURLErrorResourceUnavailable || error.code == NSURLErrorInternationalRoamingOff {
						reject(CloudProviderError.noInternetConnection)
					} else if error.domain == kGTLRErrorObjectDomain, error.code == 401 || error.code == 403 {
						reject(CloudProviderError.unauthorized)
					} else if error.domain == kGTLRErrorObjectDomain, error.code == 404 {
						reject(CloudProviderError.itemNotFound)
					} else if error.domain == kGTLRErrorObjectDomain, error.code == 507 {
						// This has never been verified and Google Drive API documentation is sparse.
						reject(CloudProviderError.quotaInsufficient)
					} else {
						reject(error)
					}
					return
				}
				if let result = result {
					fulfill(result)
				} else {
					fulfill(())
				}
			}
			self.runningTickets.append(ticket)
		}
	}

	private func executeFetcher(_ fetcher: GTMSessionFetcher) -> Promise<Void> {
		return Promise<Void> { fulfill, reject in
			self.runningFetchers.append(fetcher)
			fetcher.beginFetch { _, error in
				self.runningFetchers.removeAll { $0 == fetcher }
				if let error = error as NSError? {
					if error.domain == kGTMSessionFetcherStatusDomain, error.code == 401 {
						reject(CloudProviderError.unauthorized)
					} else if error.domain == kGTMSessionFetcherStatusDomain, error.code == 404 {
						reject(CloudProviderError.itemNotFound)
					} else {
						reject(error)
					}
					return
				}
				fulfill(())
			}
		}
	}

	// MARK: - Helpers

	private func convertToCloudItemMetadata(_ file: GTLRDrive_File, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		let name = cloudPath.lastPathComponent
		let itemType = file.getCloudItemType()
		let lastModifiedDate = file.modifiedTime?.date
		let size = file.size?.intValue
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
	}

	func onlyItemNameChangedBetween(_ lhs: CloudPath, and rhs: CloudPath) -> Bool {
		let lhsWithoutItemName = lhs.deletingLastPathComponent()
		let rhsWithoutItemName = rhs.deletingLastPathComponent()
		return lhsWithoutItemName == rhsWithoutItemName
	}
}
