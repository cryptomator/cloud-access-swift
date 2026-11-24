//
//  PCloudCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 16.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

public final class PCloudCloudProvider: CloudProvider {
	private typealias Preflight = IdentifierAddressedPreflight<PCloudItem>

	/// The API error codes that the provider maps to a `CloudProviderError`.
	private enum APIErrorCode {
		static let componentOfParentDirectoryDoesNotExist = 2002
		static let accessDenied = 2003
		static let folderAlreadyExists = 2004
		static let folderDoesNotExist = 2005
		static let userIsOverQuota = 2008
		static let fileDoesNotExist = 2009
		static let folderHasActiveShares = 2028
	}

	private let client: PCloudClient
	private let identifierCache: IdentifierCache<PCloudItem>
	let directoryContentCache: DirectoryContentCache
	let tmpDirURL: URL

	/// - Parameter maxPageSize: The maximum number of items on a page of a folder listing. pCloud lists a folder in one response, whose items the provider saves on disk and returns page by page.
	public convenience init(credential: PCloudCredential, maxPageSize: Int = .max) throws {
		try self.init(client: .foreground(tokenSource: credential.tokenSource), maxPageSize: maxPageSize)
	}

	/**
	 Creates a pCloud provider whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests, including folder listings, run on a foreground URL session.

	 - Parameter maxPageSize: The maximum number of items on a page of a folder listing. pCloud lists a folder in one response, whose items the provider saves on disk and returns page by page.
	 - Parameter sharedContainerIdentifier: The container into which the background URL session downloads files, which an app extension must share with its app, or `nil` in the app.
	 */
	public static func withBackgroundSession(credential: PCloudCredential, maxPageSize: Int = .max, sessionIdentifier: String, sharedContainerIdentifier: String?) throws -> PCloudCloudProvider {
		return try PCloudCloudProvider(client: .background(tokenSource: credential.tokenSource, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier), maxPageSize: maxPageSize)
	}

	convenience init(client: PCloudClient, maxPageSize: Int = .max) throws {
		try self.init(client: client) { tmpDirURL in
			try DirectoryContentDBCache(fileAt: tmpDirURL.appendingPathComponent("db.sqlite"), maxPageSize: maxPageSize)
		}
	}

	convenience init(client: PCloudClient, directoryContentCache: DirectoryContentCache) throws {
		try self.init(client: client) { _ in directoryContentCache }
	}

	/// - Parameter makeDirectoryContentCache: Creates the cache of the listings' snapshots, given the provider's temporary directory.
	private init(client: PCloudClient, makeDirectoryContentCache: (URL) throws -> DirectoryContentCache) throws {
		self.client = client
		self.identifierCache = try IdentifierCache<PCloudItem>()
		self.tmpDirURL = try ProcessTemporaryDirectory.shared.makeDirectory()
		self.directoryContentCache = try makeDirectoryContentCache(tmpDirURL)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
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
		if let pageToken {
			return try directoryContentCache.getPage(for: cloudPath, pageToken: pageToken)
		}
		let changeMark = try identifierCache.changeMark()
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		return try await fetchItemList(for: item, changeMark: changeMark)
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
		let upload = try await preflight.prepareUpload(from: localURL, to: cloudPath, replaceExisting: replaceExisting)
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

	private func fetchItemMetadata(for item: PCloudItem) async throws -> CloudItemMetadata {
		if item.effectiveItemType == .file {
			return try await fetchFileMetadata(for: item)
		} else if item.effectiveItemType == .folder {
			return try await fetchFolderMetadata(for: item)
		} else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemMetadata(for: \(item.identifier)) failed with error: \(error)")
			throw error
		}
	}

	private func fetchFileMetadata(for item: PCloudItem) async throws -> CloudItemMetadata {
		assert(item.effectiveItemType == .file)
		return try await perform("fetchFileMetadata(for: \(item.identifier))", mapping: [APIErrorCode.fileDoesNotExist: .itemNotFound]) {
			let metadata = try await client.stat(fileID: item.identifier)
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchFileMetadata(for: \(item.identifier)) received metadata: \(metadata)")
			return try convertToCloudItemMetadata(metadata, at: item.cloudPath)
		}
	}

	private func fetchFolderMetadata(for item: PCloudItem) async throws -> CloudItemMetadata {
		assert(item.effectiveItemType == .folder)
		return try await perform("fetchFolderMetadata(for: \(item.identifier))", mapping: [APIErrorCode.folderDoesNotExist: .itemNotFound]) {
			let metadata = try await withListing(of: item) { listing in listing.folder }
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchFolderMetadata(for: \(item.identifier)) received metadata: \(metadata)")
			return try convertToCloudItemMetadata(metadata, at: item.cloudPath)
		}
	}

	private func fetchItemList(for item: PCloudItem, changeMark: ChangeMark) async throws -> CloudItemList {
		return try await perform("fetchItemList(for: \(item.identifier))", mapping: [APIErrorCode.folderDoesNotExist: .itemNotFound]) {
			guard item.effectiveItemType == .folder else {
				throw CloudProviderError.itemTypeMismatch
			}
			let itemList = try await withListing(of: item) { listing in
				try await directoryContentCache.publishSnapshot(of: item.cloudPath) { snapshot in
					try fillSnapshot(snapshot, from: listing, of: item, changeMark: changeMark)
				}
			}
			CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemList(for: \(item.identifier)) received first page of \(itemList.items.count) items")
			return itemList
		}
	}

	private func downloadFile(for item: PCloudItem, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("PCloudCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) called")
		guard item.effectiveItemType == .file else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("PCloudCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) failed with error: \(error)")
			throw error
		}
		let remoteMetadata = try await fetchFileMetadata(for: item)
		try Task.checkCancellation()
		let fileLink = try await getFileLink(for: item)
		try Task.checkCancellation()
		let metadata = try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			try await downloadFileLink(fileLink, of: item, to: stagedFile, progress: progress, onTaskCreation: onTaskCreation)
			return remoteMetadata
		})
		CloudAccessDDLogDebug("PCloudCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) finished")
		return metadata
	}

	private func getFileLink(for item: PCloudItem) async throws -> PCloudFileLink {
		assert(item.effectiveItemType == .file)
		return try await perform("getFileLink(for: \(item.identifier))", mapping: [APIErrorCode.fileDoesNotExist: .itemNotFound]) {
			let fileLink = try await client.getFileLink(fileID: item.identifier)
			// The file link grants access to the file's content, so it isn't logged.
			CloudAccessDDLogDebug("PCloudCloudProvider: getFileLink(for: \(item.identifier)) received file link")
			return fileLink
		}
	}

	private func downloadFileLink(_ fileLink: PCloudFileLink, of item: PCloudItem, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws {
		try await perform("downloadFileLink(of: \(item.identifier), to: \(localURL))", mapping: [:], describe: PCloudError.descriptionWithoutMessage(of:)) {
			try await client.download(fileLink, to: localURL, progress: progress, onTaskCreation: onTaskCreation)
			CloudAccessDDLogDebug("PCloudCloudProvider: downloadFileLink(of: \(item.identifier), to: \(localURL)) finished")
		}
	}

	private func uploadFile(_ upload: Preflight.Upload, to cloudPath: CloudPath, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		let parentItem = upload.parent
		let localURL = upload.file.url
		return try await perform("uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path))", mapping: [APIErrorCode.folderDoesNotExist: .parentFolderDoesNotExist, APIErrorCode.userIsOverQuota: .quotaInsufficient]) {
			let metadata = try await client.upload(fromFile: localURL, parentID: parentItem.identifier, name: cloudPath.lastPathComponent, progress: progress, onTaskCreation: onTaskCreation)
			CloudAccessDDLogDebug("PCloudCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path)) received metadata: \(metadata)")
			let item = try PCloudItem(cloudPath: cloudPath, metadata: metadata)
			try identifierCache.commitMutation(item, ifStillBelow: parentItem, unchangedSince: upload.changeMark)
			return try convertToCloudItemMetadata(metadata, at: cloudPath)
		}
	}

	private func createFolder(_ creation: Preflight.CreateFolder, with name: String) async throws {
		let parentItem = creation.parent
		try await perform("createFolder(for: \(parentItem.identifier), with: \(name))", mapping: [APIErrorCode.componentOfParentDirectoryDoesNotExist: .parentFolderDoesNotExist, APIErrorCode.folderAlreadyExists: .itemAlreadyExists, APIErrorCode.userIsOverQuota: .quotaInsufficient]) {
			let metadata = try await withoutCancellation {
				try await self.client.createFolder(name: name, parentID: parentItem.identifier)
			}
			CloudAccessDDLogDebug("PCloudCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) received metadata: \(metadata)")
			let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
			let item = try PCloudItem(cloudPath: cloudPath, metadata: metadata)
			try identifierCache.commitMutation(item, ifStillBelow: parentItem, unchangedSince: creation.changeMark)
		}
	}

	private func deleteFile(for item: PCloudItem) async throws {
		try await perform("deleteFile(for: \(item.identifier))", mapping: [APIErrorCode.fileDoesNotExist: .itemNotFound, APIErrorCode.accessDenied: .deletionIncomplete]) {
			try await preflight.commitDelete(item) {
				try await withoutCancellation {
					try await self.client.deleteFile(item.identifier)
				}
				CloudAccessDDLogDebug("PCloudCloudProvider: deleteFile(for: \(item.identifier)) finished")
			}
		}
	}

	/// A refused delete throws `deletionIncomplete`, because pCloud doesn't document whether a refused recursive delete removed part of the folder.
	private func deleteFolder(for item: PCloudItem) async throws {
		try await perform("deleteFolder(for: \(item.identifier))", mapping: [APIErrorCode.folderDoesNotExist: .itemNotFound, APIErrorCode.accessDenied: .deletionIncomplete, APIErrorCode.folderHasActiveShares: .deletionIncomplete]) {
			try await preflight.commitDelete(item) {
				try await withoutCancellation {
					try await self.client.deleteFolderRecursive(item.identifier)
				}
				CloudAccessDDLogDebug("PCloudCloudProvider: deleteFolder(for: \(item.identifier)) finished")
			}
		}
	}

	private func moveFile(_ move: Preflight.Move, to targetCloudPath: CloudPath) async throws {
		let sourceItem = move.source
		let targetParentItem = move.targetParent
		try await perform("moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path))", mapping: [APIErrorCode.folderDoesNotExist: .parentFolderDoesNotExist, APIErrorCode.fileDoesNotExist: .itemNotFound, APIErrorCode.userIsOverQuota: .quotaInsufficient]) {
			try await preflight.commitMove(move, to: targetCloudPath) {
				// `renamefile` replaces a file at the target and has no parameter to refuse, whereas `renamefolder` refuses with 2004. A file that another client creates at the target after the preflight's target lookup is therefore replaced.
				let metadata = try await withoutCancellation {
					try await self.client.renameFile(sourceItem.identifier, toParent: targetParentItem.identifier, name: targetCloudPath.lastPathComponent)
				}
				CloudAccessDDLogDebug("PCloudCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received metadata: \(metadata)")
				return try PCloudItem(cloudPath: targetCloudPath, metadata: metadata)
			}
		}
	}

	private func moveFolder(_ move: Preflight.Move, to targetCloudPath: CloudPath) async throws {
		let sourceItem = move.source
		let targetParentItem = move.targetParent
		try await perform("moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path))", mapping: [APIErrorCode.folderAlreadyExists: .itemAlreadyExists, APIErrorCode.folderDoesNotExist: .itemNotFound, APIErrorCode.userIsOverQuota: .quotaInsufficient]) {
			try await preflight.commitMove(move, to: targetCloudPath) {
				let metadata = try await withoutCancellation {
					try await self.client.renameFolder(sourceItem.identifier, toParent: targetParentItem.identifier, name: targetCloudPath.lastPathComponent)
				}
				CloudAccessDDLogDebug("PCloudCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) received metadata: \(metadata)")
				return try PCloudItem(cloudPath: targetCloudPath, metadata: metadata)
			}
		}
	}

	// MARK: - Resolve Path

	private var preflight: Preflight {
		return Preflight(cache: identifierCache, providerName: "PCloudCloudProvider", lookUp: getPCloudItem(for:withParentItem:))
	}

	private func resolvePath(forItemAt cloudPath: CloudPath) async throws -> PCloudItem {
		return try await preflight.resolve(at: cloudPath)
	}

	/// Returns the child of the name in the folder, preferring a folder as `child(named:in:)` does, or `nil` if the folder holds none. A missing folder throws `CloudProviderError.itemNotFound`.
	private func getPCloudItem(for name: String, withParentItem parentItem: PCloudItem) async throws -> PCloudItem? {
		return try await perform("getPCloudItem(for: \(name), withParentItem: \(parentItem.identifier))", mapping: [APIErrorCode.folderDoesNotExist: .itemNotFound]) {
			guard let content = try await child(named: name, in: parentItem) else {
				return nil
			}
			CloudAccessDDLogDebug("PCloudCloudProvider: getPCloudItem(for: \(name), withParentItem: \(parentItem.identifier)) received metadata: \(content)")
			return try PCloudItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), metadata: content)
		}
	}

	// MARK: - Helpers

	/// Downloads the folder's listing to a temporary file, which `body` reads and which is deleted afterwards.
	private func withListing<T>(of folderItem: PCloudItem, _ body: (PCloudFolderListing) async throws -> T) async throws -> T {
		let listingURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		defer {
			try? FileManager.default.removeItem(at: listingURL)
		}
		let listing = try await client.listFolder(folderItem.identifier, to: listingURL)
		try Task.checkCancellation()
		return try await body(listing)
	}

	/**
	 Passes the children of a listing, in order, to `body` until it returns false. A child after that isn't decoded.

	 - Throws: `PCloudError.unexpectedContent` if the listing has no `contents`.
	 */
	private func forEachChild(of listing: PCloudFolderListing, _ body: (PCloudMetadata) throws -> Bool) throws {
		guard listing.hasContents else {
			throw PCloudError.unexpectedContent
		}
		try PCloudListingReader.forEachChild(inFileAt: listing.fileURL) { element in
			try body(PCloudJSON.child(in: element))
		}
	}

	/// Returns the child of the given name, preferring a folder, because pCloud allows a file and a folder of the same name in one folder. A child after a folder of that name isn't decoded.
	private func child(named name: String, in folderItem: PCloudItem) async throws -> PCloudMetadata? {
		return try await withListing(of: folderItem) { listing in
			var match: PCloudMetadata?
			try forEachChild(of: listing) { child in
				guard child.name == name else {
					return true
				}
				match = child
				return !child.isFolder
			}
			return match
		}
	}

	/**
	 Saves the children of the listing in the snapshot and caches the items that the cache accepts (see `IdentifierCache.addOrUpdate(_:ifStillBelow:unchangedSince:)`), stopping at the next child once the task is cancelled.

	 A name that a file and a folder share caches the folder, as `child(named:in:)` resolves it. Once a file overwrites a cached folder, the listing's folders are cached again, because that folder may be listed before the file. The overwrite drops the items cached below that folder, so they are looked up again. This happens even if the fill fails or is cancelled, and the fill's error is thrown afterwards. A cached folder that the listing no longer holds stays overwritten by the file.
	 */
	private func fillSnapshot(_ snapshot: DirectoryContentSnapshot, from listing: PCloudFolderListing, of folderItem: PCloudItem, changeMark: ChangeMark) throws {
		let folderPath = snapshot.folderEnumerationPath
		var index: Int64 = 0
		var overwroteCachedFolder = false
		do {
			try forEachChild(of: listing) { child in
				try Task.checkCancellation()
				guard child.name.isSinglePathComponent else {
					CloudAccessDDLogDebug("PCloudCloudProvider: skipping item \(child.name) in \(folderPath.path), because its name is no single path component")
					return true
				}
				let childPath = folderPath.appendingPathComponent(child.name)
				let outcome = try identifierCache.addOrUpdate(PCloudItem(cloudPath: childPath, metadata: child), ifStillBelow: folderItem, unchangedSince: changeMark)
				if !child.isFolder, case let .saved(replacedItem) = outcome, replacedItem?.itemType == .folder {
					overwroteCachedFolder = true
				}
				index += 1
				try directoryContentCache.save(convertToCloudItemMetadata(child, at: childPath), in: snapshot, index: index)
				return true
			}
		} catch {
			if overwroteCachedFolder {
				try? cacheFolders(of: listing, in: folderItem, changeMark: changeMark)
			}
			throw error
		}
		if overwroteCachedFolder {
			try cacheFolders(of: listing, in: folderItem, changeMark: changeMark)
		}
	}

	private func cacheFolders(of listing: PCloudFolderListing, in folderItem: PCloudItem, changeMark: ChangeMark) throws {
		try forEachChild(of: listing) { child in
			if child.isFolder, child.name.isSinglePathComponent {
				try identifierCache.addOrUpdate(PCloudItem(cloudPath: folderItem.cloudPath.appendingPathComponent(child.name), metadata: child), ifStillBelow: folderItem, unchangedSince: changeMark)
			}
			return true
		}
	}

	/// Logs the request and maps the API error codes that `mapping` lists. Any other error passes through unchanged.
	private func perform<T>(_ operation: String, mapping: [Int: CloudProviderError], describe: (Error) -> String = { "\($0)" }, _ body: () async throws -> T) async throws -> T {
		try await performLogged(operation, by: "PCloudCloudProvider", convert: { PCloudCloudProvider.convertAPIError($0, mapping: mapping) }, describe: describe, body)
	}

	private static func convertAPIError(_ error: Error, mapping: [Int: CloudProviderError]) -> Error {
		guard case let PCloudError.apiError(code, _) = error, let mappedError = mapping[code] else {
			return error
		}
		return mappedError
	}

	private func convertToCloudItemMetadata(_ metadata: PCloudMetadata, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		let lastModifiedDate = Date(timeIntervalSince1970: TimeInterval(metadata.modified))
		if metadata.isFolder {
			return CloudItemMetadata(name: metadata.name, cloudPath: cloudPath, itemType: .folder, lastModifiedDate: lastModifiedDate, size: nil)
		}
		guard let size = metadata.size else {
			throw PCloudError.unexpectedContent
		}
		return CloudItemMetadata(name: metadata.name, cloudPath: cloudPath, itemType: .file, lastModifiedDate: lastModifiedDate, size: Int(truncatingIfNeeded: size))
	}
}
