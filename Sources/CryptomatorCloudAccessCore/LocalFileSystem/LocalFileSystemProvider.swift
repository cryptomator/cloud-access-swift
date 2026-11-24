//
//  LocalFileSystemProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Wahid Ali on 27.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

private extension FileManager {
	func copyItemWithOverwrite(at srcURL: URL, to dstURL: URL) throws {
		let tmpDstURL = dstURL.appendingPathExtension(UUID().uuidString)
		try? moveItem(at: dstURL, to: tmpDstURL)
		do {
			try copyItem(at: srcURL, to: dstURL)
		} catch {
			try? removeItem(at: dstURL)
			try? moveItem(at: tmpDstURL, to: dstURL)
			throw error
		}
		try? removeItem(at: tmpDstURL)
	}
}

/**
 Cloud provider for local file system.

 Since the local file system is not actually a cloud, the naming might be confusing. However, iCloud Drive can be accessed via the local file system and this provider contains code to handle offloaded items.
 */
public final class LocalFileSystemProvider: CloudProvider {
	// iCloud Drive offloads an item as `.<name>.icloud`, but with two leading dots if its name starts with `_`, so the pattern accepts any number of them.
	// See: https://github.com/cryptomator/cloud-access-swift/issues/19
	// swiftlint:disable:next force_try
	private static let iCloudPlaceholderRegex = try! NSRegularExpression(pattern: #"^\.+(.*)\.icloud$"#, options: [])

	private let rootURL: URL
	private let queue = OperationQueue()
	private let shouldStopAccessingRootURL: Bool
	private let maxPageSize: Int
	let cache: DirectoryContentCache
	private let tmpDirURL: URL
	private let securityScopedAccess: (start: @Sendable (URL) -> Bool, stop: @Sendable (URL) -> Void)

	public convenience init(rootURL: URL, maxPageSize: Int = .max) throws {
		try self.init(rootURL: rootURL, maxPageSize: maxPageSize, securityScopedAccess: (start: { $0.startAccessingSecurityScopedResource() }, stop: { $0.stopAccessingSecurityScopedResource() }))
	}

	init(rootURL: URL, maxPageSize: Int = .max, securityScopedAccess: (start: @Sendable (URL) -> Bool, stop: @Sendable (URL) -> Void)) throws {
		precondition(rootURL.isFileURL)
		self.rootURL = rootURL
		self.securityScopedAccess = securityScopedAccess
		self.shouldStopAccessingRootURL = securityScopedAccess.start(rootURL)
		self.maxPageSize = maxPageSize
		self.tmpDirURL = try ProcessTemporaryDirectory.shared.makeDirectory()
		let dbURL = tmpDirURL.appending(component: "db.sqlite")
		self.cache = try DirectoryContentDBCache(fileAt: dbURL, maxPageSize: maxPageSize)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
		if shouldStopAccessingRootURL {
			securityScopedAccess.stop(rootURL)
		}
	}

	// MARK: - CloudProvider API

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		let url = rootURL.appending(cloudPath: cloudPath)
		return try await withSecurityScopedAccess(to: url, "fetchItemMetadata(at: \(cloudPath.path))") {
			try await getItemMetadata(forItemAt: url, parentCloudPath: cloudPath.deletingLastPathComponent())
		}
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		if let pageToken {
			return try cache.getPage(for: cloudPath, pageToken: pageToken)
		}
		return try await cache.publishSnapshot(of: cloudPath) { snapshot in
			try await fillCache(snapshot)
		}
	}

	private func fillCache(_ snapshot: DirectoryContentSnapshot) async throws {
		let cloudPath = snapshot.folderEnumerationPath
		let url = rootURL.appending(cloudPath: cloudPath)
		let operation = "fillCache(\(cloudPath.path))"
		try await withSecurityScopedAccess(to: url, operation) {
			let readingIntent = NSFileAccessIntent.readingIntent(with: url)
			let childURLs = try await coordinated(readingIntent, operation, convert: convertStandardError) { coordinatedURL in
				try self.validateIsFolder(at: coordinatedURL)
				guard let directoryEnumerator = FileManager.default.enumerator(at: coordinatedURL, includingPropertiesForKeys: [.isHiddenKey], options: .skipsSubdirectoryDescendants) else {
					throw CloudProviderError.pageTokenInvalid
				}
				return directoryEnumerator.compactMap { $0 as? URL }
			}
			try await fillCacheAfterCheck(snapshot, url: url, childURLs: childURLs)
		}
	}

	private func validateIsFolder(at url: URL) throws {
		let attributes = try url.promisedItemResourceValues(forKeys: [.isDirectoryKey])
		guard attributes.isDirectory ?? false else {
			throw CloudProviderError.itemTypeMismatch
		}
	}

	private func fillCacheAfterCheck(_ snapshot: DirectoryContentSnapshot, url: URL, childURLs: [URL]) async throws {
		let cloudPath = snapshot.folderEnumerationPath
		do {
			var cachedItemsCount: Int64 = 0
			for childURL in childURLs {
				try Task.checkCancellation()
				guard !childURL.isHidden || FileManager.default.isUbiquitousItem(at: childURL) else {
					continue
				}
				let iCloudCompatibleChildURL = url.appending(component: getItemName(forItemAt: childURL))
				guard !iCloudCompatibleChildURL.lastPathComponent.hasUTF8Prefix(".") else {
					continue
				}
				do {
					let childItemMetadata = try await getItemMetadata(forItemAt: iCloudCompatibleChildURL, parentCloudPath: cloudPath)
					cachedItemsCount += 1
					try cache.save(childItemMetadata, in: snapshot, index: cachedItemsCount)
				} catch CloudProviderError.itemNotFound {
					// Ignore item that can't be found anyway, this should not prevent fetching item list
				}
			}
			CloudAccessDDLogDebug("LocalFileSystemProvider: fillCache(\(cloudPath.path)) finished")
		} catch {
			CloudAccessDDLogDebug("LocalFileSystemProvider: fillCache(\(cloudPath.path)) failed with error: \(error)")
			throw error
		}
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let url = rootURL.appending(cloudPath: cloudPath)
		let operation = "downloadFile(from: \(cloudPath.path) to: \(localURL))"
		return try await withSecurityScopedAccess(to: url, operation) {
			let phases = Progress.phases(of: progress, 999)
			let readingIntent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
			let metadata = try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
				try await coordinated(readingIntent, operation, convert: convertStandardError) { coordinatedURL in
					guard try self.validateItemType(at: coordinatedURL, with: .file) else {
						throw CloudProviderError.itemTypeMismatch
					}
					// The modification date is read before the content is copied, so that it's never newer than the copy
					let sourceMetadata = try self.readItemMetadata(forItemAt: url, coordinatedURL: coordinatedURL, parentCloudPath: cloudPath.deletingLastPathComponent())
					try FileManager.default.copyItem(at: coordinatedURL, to: stagedFile)
					return sourceMetadata
				}
			})
			CloudAccessDDLogDebug("LocalFileSystemProvider: \(operation) finished")
			phases.completeTransfer()
			return metadata
		}
	}

	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let url = rootURL.appending(cloudPath: cloudPath)
		let operation = "uploadFile(from: \(localURL) to: \(cloudPath.path), replaceExisting: \(replaceExisting))"
		return try await withSecurityScopedAccess(to: url, operation) {
			let phases = Progress.phases(of: progress, 999)
			let writingIntent = NSFileAccessIntent.writingIntent(with: url, options: replaceExisting ? .forReplacing : [])
			try await coordinated(writingIntent, operation, convert: convertCreationError) { coordinatedURL in
				try self.validateAndCopyFile(from: localURL, to: coordinatedURL, replaceExisting: replaceExisting)
				CloudAccessDDLogDebug("LocalFileSystemProvider: \(operation) finished, getting metadata…")
			}
			let metadata = try await getItemMetadata(forItemAt: url, parentCloudPath: cloudPath.deletingLastPathComponent())
			phases.completeTransfer()
			return metadata
		}
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let url = rootURL.appending(cloudPath: cloudPath)
		let operation = "createFolder(at: \(cloudPath.path))"
		try await withSecurityScopedAccess(to: url, operation) {
			let writingIntent = NSFileAccessIntent.writingIntent(with: url, options: [])
			try await coordinated(writingIntent, operation, convert: convertCreationError) { coordinatedURL in
				try FileManager.default.createDirectory(at: coordinatedURL, withIntermediateDirectories: false, attributes: nil)
				CloudAccessDDLogDebug("LocalFileSystemProvider: \(operation) finished")
			}
		}
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await deleteItem(at: cloudPath, type: .file)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await deleteItem(at: cloudPath, type: .folder)
	}

	private func deleteItem(at cloudPath: CloudPath, type: CloudItemType) async throws {
		let url = rootURL.appending(cloudPath: cloudPath)
		let operation = "deleteItem(at: \(cloudPath.path))"
		try await withSecurityScopedAccess(to: url, operation) {
			let writingIntent = NSFileAccessIntent.writingIntent(with: url, options: .forDeleting)
			try await coordinated(writingIntent, operation, convert: { error in
				switch error {
				case _ where isNotDirectoryError(error), CocoaError.fileNoSuchFile:
					return CloudProviderError.itemNotFound
				default:
					return error
				}
			}, body: { coordinatedURL in
				try self.checkSourceType(at: coordinatedURL, type: type)
				try FileManager.default.removeItem(at: coordinatedURL)
				CloudAccessDDLogDebug("LocalFileSystemProvider: \(operation) finished")
			})
		}
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await moveItem(from: sourceCloudPath, to: targetCloudPath, type: .file)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await moveItem(from: sourceCloudPath, to: targetCloudPath, type: .folder)
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath, type: CloudItemType) async throws {
		let sourceURL = rootURL.appending(cloudPath: sourceCloudPath)
		let targetURL = rootURL.appending(cloudPath: targetCloudPath)
		let operation = "moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path))"
		try await withSecurityScopedAccess(to: sourceURL, operation) {
			let writingIntent = NSFileAccessIntent.writingIntent(with: sourceURL, options: .forMoving)
			try await coordinated(writingIntent, operation, convert: { error in
				switch error {
				case _ where isNotDirectoryError(error), CocoaError.fileNoSuchFile:
					var isDirectory: ObjCBool = false
					let targetParentIsFolder = FileManager.default.fileExists(atPath: targetURL.deletingLastPathComponent().path, isDirectory: &isDirectory) && isDirectory.boolValue
					return targetParentIsFolder ? CloudProviderError.itemNotFound : CloudProviderError.parentFolderDoesNotExist
				case CocoaError.fileWriteFileExists:
					return CloudProviderError.itemAlreadyExists
				case CocoaError.fileWriteOutOfSpace:
					return CloudProviderError.quotaInsufficient
				default:
					return error
				}
			}, body: { coordinatedURL in
				try self.checkSourceType(at: coordinatedURL, type: type)
				try FileManager.default.moveItem(at: coordinatedURL, to: targetURL)
				CloudAccessDDLogDebug("LocalFileSystemProvider: \(operation) finished")
			})
		}
	}

	// MARK: - Internal

	/**
	 Throws an error of the file coordinator itself as it is, and an error that `body` throws as `convert` maps it.

	 Uses a file coordinator per access, because accesses through the same file coordinator never wait for each other.
	 */
	private func coordinated<T>(_ intent: NSFileAccessIntent, _ operation: String, convert: @escaping @Sendable (Error) -> Error, body: @escaping @Sendable (URL) throws -> T) async throws -> T {
		return try await withSDKContinuation { (resumer: Resumer<T>) in
			NSFileCoordinator().coordinate(with: [intent], queue: queue) { error in
				if let error {
					CloudAccessDDLogDebug("LocalFileSystemProvider: \(operation) failed coordinated access with error: \(error)")
					resumer.resume(throwing: error)
					return
				}
				do {
					try resumer.resume(returning: body(intent.url))
				} catch {
					CloudAccessDDLogDebug("LocalFileSystemProvider: \(operation) failed with error: \(error)")
					resumer.resume(throwing: convert(error))
				}
			}
		}
	}

	private func withSecurityScopedAccess<T>(to url: URL, _ operation: String, _ body: () async throws -> T) async rethrows -> T {
		let shouldStopAccessing = securityScopedAccess.start(url)
		defer {
			if shouldStopAccessing {
				securityScopedAccess.stop(url)
			}
		}
		CloudAccessDDLogDebug("LocalFileSystemProvider: \(operation) called with startAccessingSecurityScopedResource: \(shouldStopAccessing)")
		return try await body()
	}

	private func getItemType(from url: URL) throws -> CloudItemType {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		return getItemType(from: attributes[FileAttributeKey.type] as? FileAttributeType)
	}

	private func getItemType(from fileAttributeType: FileAttributeType?) -> CloudItemType {
		switch fileAttributeType {
		case FileAttributeType.typeDirectory:
			return CloudItemType.folder
		case FileAttributeType.typeRegular:
			return CloudItemType.file
		default:
			return CloudItemType.unknown
		}
	}

	private func getItemType(from fileResourceType: URLFileResourceType?) -> CloudItemType {
		switch fileResourceType {
		case URLFileResourceType.directory:
			return CloudItemType.folder
		case URLFileResourceType.regular:
			return CloudItemType.file
		default:
			return CloudItemType.unknown
		}
	}

	private func validateItemType(at url: URL, with itemType: CloudItemType) throws -> Bool {
		return try getItemType(from: url) == itemType
	}

	/**
	 Checks that an operation on items of `type` accepts the item at the URL, which must be the URL of a coordinated delete or move. The item's own type counts, so a symbolic link to a folder is no folder. It is read as a promised item, whose content need not be on disk, e.g., an evicted iCloud file.

	 A missing item, or one below a file, is left to the delete or move, whose error mapping reports it. The check and the delete or move are separate calls, so only file coordination keeps another writer from changing the item in between.

	 - Throws: `CloudProviderError.itemTypeMismatch` if the operation doesn't accept the item, or the error of reading its type for any other reason.
	 */
	private func checkSourceType(at url: URL, type: CloudItemType) throws {
		let resourceType: URLFileResourceType?
		do {
			resourceType = try url.promisedItemResourceValues(forKeys: [.fileResourceTypeKey]).fileResourceType
		} catch CocoaError.fileReadNoSuchFile {
			return
		} catch where isNotDirectoryError(error) {
			return
		}
		let itemType = resourceType == .symbolicLink ? CloudItemType.symlink : getItemType(from: resourceType)
		guard itemType.isTaken(byOperationOn: type) else {
			throw CloudProviderError.itemTypeMismatch
		}
	}

	func getItemName(forItemAt url: URL) -> String {
		CloudAccessDDLogDebug("LocalFileSystemProvider: getItemName(forItemAt: \(url)) called")
		let name = url.lastPathComponent
		let range = NSRange(name.startIndex ..< name.endIndex, in: name)
		guard let match = LocalFileSystemProvider.iCloudPlaceholderRegex.firstMatch(in: name, options: [], range: range), let matchedRange = Range(match.range(at: 1), in: name) else {
			return name
		}
		let originalName = String(name[matchedRange])
		// A placeholder of dots alone, e.g. `..icloud`, keeps its name, because the empty stripped name would address the folder itself.
		return originalName.isSinglePathComponent ? originalName : name
	}

	/// Doesn't check for cancellation, so that an upload can still fetch the metadata to return after its change.
	private func getItemMetadata(forItemAt url: URL, parentCloudPath: CloudPath) async throws -> CloudItemMetadata {
		let operation = "getItemMetadata(forItemAt: \(url), parentCloudPath: \(parentCloudPath.path))"
		CloudAccessDDLogDebug("LocalFileSystemProvider: \(operation) called")
		let readingIntent = NSFileAccessIntent.readingIntent(with: url, options: .immediatelyAvailableMetadataOnly)
		return try await coordinated(readingIntent, operation, convert: convertStandardError) { coordinatedURL in
			try self.readItemMetadata(forItemAt: url, coordinatedURL: coordinatedURL, parentCloudPath: parentCloudPath)
		}
	}

	private func readItemMetadata(forItemAt url: URL, coordinatedURL: URL, parentCloudPath: CloudPath) throws -> CloudItemMetadata {
		let attributes = try coordinatedURL.promisedItemResourceValues(forKeys: [.nameKey, .fileSizeKey, .contentModificationDateKey, .fileResourceTypeKey])
		CloudAccessDDLogDebug("LocalFileSystemProvider: getItemMetadata(forItemAt: \(url), parentCloudPath: \(parentCloudPath.path)) read attributes: \(attributes.allValues.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value })")
		let name = attributes.name ?? url.lastPathComponent
		let size = attributes.fileSize
		let lastModifiedDate = attributes.contentModificationDate
		let itemType = getItemType(from: attributes.fileResourceType)
		return CloudItemMetadata(name: name, cloudPath: parentCloudPath.appendingPathComponent(name), itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
	}

	private func validateAndCopyFile(from sourceURL: URL, to targetURL: URL, replaceExisting: Bool) throws {
		let sourceFile = try LocalUploadFile(sourceURL)
		if replaceExisting {
			do {
				guard try validateItemType(at: targetURL, with: .file) else {
					throw CloudProviderError.itemAlreadyExists
				}
			} catch CocoaError.fileReadNoSuchFile {
				// no-op
			}
			try FileManager.default.copyItemWithOverwrite(at: sourceFile.url, to: targetURL)
		} else {
			try FileManager.default.copyItem(at: sourceFile.url, to: targetURL)
		}
	}

	func convertStandardError(_ error: Error) -> Error {
		switch error {
		case _ where isNotDirectoryError(error), CocoaError.fileReadNoSuchFile:
			return CloudProviderError.itemNotFound
		default:
			return error
		}
	}

	func convertCreationError(_ error: Error) -> Error {
		switch error {
		case CocoaError.fileReadNoSuchFile:
			return CloudProviderError.itemNotFound
		case CocoaError.fileWriteFileExists:
			return CloudProviderError.itemAlreadyExists
		case _ where isNotDirectoryError(error), CocoaError.fileNoSuchFile:
			return CloudProviderError.parentFolderDoesNotExist
		case CocoaError.fileWriteOutOfSpace:
			return CloudProviderError.quotaInsufficient
		default:
			return error
		}
	}
}

private extension URL {
	var isHidden: Bool {
		return (try? resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
	}
}

/// Tells whether the error says that an item above the target on its path is no folder. Foundation reports that as `ENOTDIR`, nested as the underlying error of a Cocoa error such as `fileReadUnknown` or `fileWriteUnknown`.
private func isNotDirectoryError(_ error: Error) -> Bool {
	let posixError = underlyingErrorChain(of: error).lazy.compactMap { $0 as? POSIXError }.first
	return posixError?.code == .ENOTDIR
}
