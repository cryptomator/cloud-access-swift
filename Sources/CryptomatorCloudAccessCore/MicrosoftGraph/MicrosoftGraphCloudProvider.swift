//
//  MicrosoftGraphCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

public final class MicrosoftGraphCloudProvider: CloudProvider {
	private typealias Preflight = IdentifierAddressedPreflight<MicrosoftGraphItem>

	/// Graph requires each chunk of an upload session but the last to be a multiple of this length.
	static let uploadSessionChunkGranularity = 320 * 1024

	private let client: MicrosoftGraphHTTPClient
	private let driveIdentifier: String?
	private let identifierCache: IdentifierCache<MicrosoftGraphItem>
	private let maxPageSize: Int
	/// The length of an upload session's chunks, a multiple of `uploadSessionChunkGranularity`. It defaults to 5 MiB.
	private let uploadSessionChunkLength: Int

	init(client: MicrosoftGraphHTTPClient, driveIdentifier: String? = nil, maxPageSize: Int = .max, uploadSessionChunkLength: Int = 16 * MicrosoftGraphCloudProvider.uploadSessionChunkGranularity) throws {
		self.client = client
		self.driveIdentifier = driveIdentifier
		self.identifierCache = try IdentifierCache<MicrosoftGraphItem>()
		self.maxPageSize = min(max(1, maxPageSize), 1000)
		self.uploadSessionChunkLength = uploadSessionChunkLength
	}

	public convenience init(credential: MicrosoftGraphCredential, driveIdentifier: String? = nil, maxPageSize: Int = .max) throws {
		try self.init(client: .foreground(tokenSource: credential.tokenSource), driveIdentifier: driveIdentifier, maxPageSize: maxPageSize)
	}

	/**
	 Creates a Microsoft Graph provider whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.

	 - Parameter sharedContainerIdentifier: The container into which the background URL session downloads files, which an app extension must share with its app, or `nil` in the app.
	 */
	public static func withBackgroundSession(credential: MicrosoftGraphCredential, driveIdentifier: String? = nil, maxPageSize: Int = .max, sessionIdentifier: String, sharedContainerIdentifier: String?) throws -> MicrosoftGraphCloudProvider {
		return try MicrosoftGraphCloudProvider(client: .background(tokenSource: credential.tokenSource, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier), driveIdentifier: driveIdentifier, maxPageSize: maxPageSize)
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
		let changeMark = try identifierCache.changeMark()
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		return try await fetchItemList(for: item, pageToken: pageToken, changeMark: changeMark)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let phases = Progress.phases(of: progress, 999)
		let (item, parentItem) = try await preflight.resolveWithParent(at: cloudPath)
		try Task.checkCancellation()
		let metadata = try await downloadFile(for: item, in: parentItem, to: localURL, progress: phases[0], onTaskCreation: onTaskCreation)
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
		try await deleteItem(for: item)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let item = try await preflight.resolveSource(at: cloudPath, type: .folder, operation: "deleteFolder")
		try await deleteItem(for: item)
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let move = try await preflight.prepareMove(from: sourceCloudPath, to: targetCloudPath, type: .file, operation: "moveFile")
		try await moveItem(move, to: targetCloudPath)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let move = try await preflight.prepareMove(from: sourceCloudPath, to: targetCloudPath, type: .folder, operation: "moveFolder")
		try await moveItem(move, to: targetCloudPath)
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: MicrosoftGraphItem) async throws -> CloudItemMetadata {
		let driveItem = try await perform { try await client.item(at: address(of: item)) }
		return try convertToCloudItemMetadata(driveItem, at: item.cloudPath)
	}

	private func fetchItemList(for item: MicrosoftGraphItem, pageToken: String?, changeMark: ChangeMark) async throws -> CloudItemList {
		guard item.effectiveItemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
		if let pageToken {
			return try await fetchItemList(for: item, withPageToken: pageToken, changeMark: changeMark)
		}
		let collection = try await perform { try await client.children(of: address(of: item), pageSize: maxPageSize) }
		return try cacheItemList(collection, in: item, changeMark: changeMark)
	}

	/// Accepts only a page token on a Graph host, because its request carries the access token.
	private func fetchItemList(for item: MicrosoftGraphItem, withPageToken pageToken: String, changeMark: ChangeMark) async throws -> CloudItemList {
		guard let url = HTTPClientSupport.httpsURL(pageToken, onDomain: MicrosoftGraphAPI.host) else {
			throw CloudProviderError.pageTokenInvalid
		}
		let collection: MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.DriveItem>
		do {
			collection = try await perform { try await client.children(nextLink: url) }
		} catch MicrosoftGraphError.unexpectedHTTPStatusCode(code: 400) {
			throw CloudProviderError.pageTokenInvalid
		}
		return try cacheItemList(collection, in: item, changeMark: changeMark)
	}

	private func cacheItemList(_ collection: MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.DriveItem>, in folderItem: MicrosoftGraphItem, changeMark: ChangeMark) throws -> CloudItemList {
		let cloudPath = folderItem.cloudPath
		var items = [CloudItemMetadata]()
		for driveItem in collection.value {
			guard let name = driveItem.name else {
				throw MicrosoftGraphError.missingItemName
			}
			guard name.isSinglePathComponent else {
				CloudAccessDDLogDebug("MicrosoftGraphCloudProvider: skipping item \(name) in \(cloudPath.path), because its name is no single path component")
				continue
			}
			let childCloudPath = cloudPath.appendingPathComponent(name)
			let child = MicrosoftGraphItem(cloudPath: childCloudPath, driveItem: driveItem)
			try identifierCache.addOrUpdate(child, ifStillBelow: folderItem, unchangedSince: changeMark)
			try items.append(convertToCloudItemMetadata(driveItem, at: childCloudPath, isAlias: child.isRemoteItem))
		}
		return CloudItemList(items: items, nextPageToken: collection.nextLink)
	}

	/// Whether the item, or the cached row of the folder that holds it, is a remote item, in which case the request reaches the remote item's target or an item inside it.
	private func isReachedThroughRemoteItem(_ item: MicrosoftGraphItem, in parentItem: MicrosoftGraphItem) -> Bool {
		return item.isRemoteItem || parentItem.isRemoteItem
	}

	/// - Parameter parentItem: The cached row of the folder that holds the item, read together with the item's.
	private func downloadFile(for item: MicrosoftGraphItem, in parentItem: MicrosoftGraphItem, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		guard item.effectiveItemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		let itemAddress = address(of: item)
		let isAlias = isReachedThroughRemoteItem(item, in: parentItem)
		let driveItem = try await perform { try await client.itemWithDownloadURL(at: itemAddress) }
		let remoteMetadata = try convertToCloudItemMetadata(driveItem, at: item.cloudPath, isAlias: isAlias)
		try Task.checkCancellation()
		return try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			if let downloadURL = MicrosoftGraphAPI.preAuthenticatedURL(driveItem.downloadURL) {
				try await download(from: downloadURL, fallingBackTo: itemAddress, to: stagedFile, progress: progress, onTaskCreation: onTaskCreation)
			} else {
				try await perform { try await client.downloadContent(of: itemAddress, to: stagedFile, progress: progress, onTaskCreation: onTaskCreation) }
			}
			return remoteMetadata
		})
	}

	/// Downloads from the pre-authenticated download URL without the access token. If the content host answers with a status outside 2xx, e.g., because the URL expired, it downloads once more through Graph with the access token. A 2xx other than 200 throws instead, because its body already occupies the staging file.
	private func download(from downloadURL: URL, fallingBackTo itemAddress: MicrosoftGraphAPI.ItemAddress, to stagingURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws {
		let response = try await perform { try await client.download(fromDownloadURL: downloadURL, to: stagingURL, progress: progress, onTaskCreation: onTaskCreation) }
		switch response.statusCode {
		case 200:
			return
		case 200 ... 299:
			throw MicrosoftGraphHTTPClient.error(forStatusCode: response.statusCode)
		default:
			CloudAccessDDLogDebug("MicrosoftGraphCloudProvider: the download URL answered \(response.statusCode), downloading the content through Graph")
			try Task.checkCancellation()
			// The fallback's task adds a unit, so that its progress doesn't push the total past complete.
			progress?.totalUnitCount += 1
			try await perform { try await client.downloadContent(of: itemAddress, to: stagingURL, progress: progress, onTaskCreation: nil) }
		}
	}

	private func uploadFile(_ upload: Preflight.Upload, to cloudPath: CloudPath, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		let uploadURL = try await perform { try await client.createUploadSession(named: cloudPath.lastPathComponent, in: address(of: upload.parent)) }
		let driveItem = try await uploadFileChunks(from: upload.file.url, to: uploadURL, totalFileSize: Int(upload.file.size), progress: progress, onTaskCreation: onTaskCreation)
		let item = MicrosoftGraphItem(cloudPath: cloudPath, driveItem: driveItem)
		try identifierCache.commitMutation(item, ifStillBelow: upload.parent, unchangedSince: upload.changeMark)
		return try convertToCloudItemMetadata(driveItem, at: cloudPath)
	}

	/**
	 Uploads the chunks one by one, each from a temporary file, so that no chunk is held in memory. The progress counts bytes, and each chunk gets a share of its length.

	 - Parameter onTaskCreation: Gets the task only if the file fits in one chunk, so that the task it gets uploads the whole file.
	 */
	private func uploadFileChunks(from localURL: URL, to uploadURL: URL, totalFileSize: Int, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> MicrosoftGraphAPI.DriveItem {
		progress?.totalUnitCount = Int64(totalFileSize)
		let taskHook = totalFileSize <= uploadSessionChunkLength ? onTaskCreation : nil
		let fileHandle = try FileHandle(forReadingFrom: localURL)
		defer {
			try? fileHandle.close()
		}
		var offset = 0
		while true {
			try Task.checkCancellation()
			let (chunkFileURL, chunkLength) = try HTTPClientSupport.writeTemporaryFile(copyingUpTo: uploadSessionChunkLength, from: fileHandle)
			defer {
				try? FileManager.default.removeItem(at: chunkFileURL)
			}
			let chunkProgress = progress?.makeExplicitChild(pendingUnitCount: Int64(chunkLength))
			if let driveItem = try await perform({ try await client.uploadChunk(to: uploadURL, fromFile: chunkFileURL, offset: offset, length: chunkLength, totalLength: totalFileSize, progress: chunkProgress, onTaskCreation: taskHook) }) {
				return driveItem
			}
			offset += chunkLength
		}
	}

	private func createFolder(_ creation: Preflight.CreateFolder, with name: String) async throws {
		let parentItem = creation.parent
		let parentAddress = address(of: parentItem)
		let driveItem = try await perform {
			try await withoutCancellation {
				try await self.client.createFolder(named: name, in: parentAddress)
			}
		}
		let item = MicrosoftGraphItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), driveItem: driveItem)
		try identifierCache.commitMutation(item, ifStillBelow: parentItem, unchangedSince: creation.changeMark)
	}

	private func deleteItem(for item: MicrosoftGraphItem) async throws {
		let itemAddress = address(of: item)
		try await preflight.commitDelete(item) {
			try await perform {
				try await withoutCancellation {
					try await self.client.delete(itemAddress)
				}
			}
		}
	}

	private func moveItem(_ move: Preflight.Move, to targetCloudPath: CloudPath) async throws {
		let sourceAddress = address(of: move.source)
		let targetParentItem = move.targetParent
		try await preflight.commitMove(move, to: targetCloudPath) {
			let driveItem = try await perform {
				try await withoutCancellation {
					try await self.client.move(sourceAddress, named: targetCloudPath.lastPathComponent, toParentID: targetParentItem.identifier, parentDriveID: targetParentItem.driveIdentifier)
				}
			}
			return MicrosoftGraphItem(cloudPath: targetCloudPath, driveItem: driveItem)
		}
	}

	// MARK: - Execution

	/// Converts the cancellation and connection errors of a client call with `convertStandardError(_:)`.
	private func perform<T>(_ request: () async throws -> T) async throws -> T {
		do {
			return try await request()
		} catch {
			throw Self.convertStandardError(error)
		}
	}

	// MARK: - Resolve Path

	private var preflight: Preflight {
		return Preflight(cache: identifierCache, providerName: "MicrosoftGraphCloudProvider", lookUp: getMicrosoftGraphItem(for:withParentItem:))
	}

	private func resolvePath(forItemAt cloudPath: CloudPath) async throws -> MicrosoftGraphItem {
		return try await preflight.resolve(at: cloudPath)
	}

	/// Returns the item of the name in the folder, or `nil` if Graph finds none. Graph answers 404 for a missing folder too, so a missing folder returns `nil` as well.
	private func getMicrosoftGraphItem(for name: String, withParentItem parentItem: MicrosoftGraphItem) async throws -> MicrosoftGraphItem? {
		do {
			let driveItem = try await perform { try await client.child(named: name, in: address(of: parentItem)) }
			return MicrosoftGraphItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), driveItem: driveItem)
		} catch CloudProviderError.itemNotFound {
			return nil
		}
	}

	// MARK: - Helpers

	private func address(of item: MicrosoftGraphItem) -> MicrosoftGraphAPI.ItemAddress {
		return MicrosoftGraphAPI.ItemAddress(driveIdentifier: item.driveIdentifier ?? driveIdentifier, itemIdentifier: item.identifier)
	}

	private func convertToCloudItemMetadata(_ driveItem: MicrosoftGraphAPI.DriveItem, at cloudPath: CloudPath, isAlias: Bool = false) throws -> CloudItemMetadata {
		guard let name = driveItem.name else {
			throw MicrosoftGraphError.missingItemName
		}
		let itemType = driveItem.cloudItemType
		let lastModifiedDate = driveItem.fileSystemInfo?.lastModifiedDate
		let size = Int(driveItem.size ?? 0)
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size, isAlias: isAlias)
	}

	static func convertStandardError(_ error: Error) -> Error {
		if isCancellationError(error) {
			return CancellationError()
		}
		return convertingNetworkConnectionError(error)
	}
}
