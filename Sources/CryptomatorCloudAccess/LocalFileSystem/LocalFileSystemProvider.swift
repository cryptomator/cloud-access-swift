//
//  LocalFileSystemProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Wahid Ali on 27.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

public enum LocalFileSystemProviderError: Error {
	case resolvingURLFailed
	case invalidState
}

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
	private let rootURL: URL
	private let queue = OperationQueue()
	private let shouldStopAccessingRootURL: Bool
	private let maxPageSize: Int
	private let cache: DirectoryContentCache
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
		self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		let dbURL = tmpDirURL.appendingPathComponent("db.sqlite")
		self.cache = try DirectoryContentDBCache(dbWriter: DatabaseQueue(path: dbURL.path), maxPageSize: maxPageSize)
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
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = securityScopedAccess.start(url)
		defer {
			if shouldStopAccessing {
				securityScopedAccess.stop(url)
			}
		}
		CloudAccessDDLogDebug("LocalFileSystemProvider: fetchItemMetadata(at: \(cloudPath.path)) called with startAccessingSecurityScopedResource: \(shouldStopAccessing)")
		return try await getItemMetadata(forItemAt: url, parentCloudPath: cloudPath.deletingLastPathComponent())
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		if pageToken == nil {
			try await fillCache(for: cloudPath)
		}
		let itemList = try getCachedElements(for: cloudPath, pageToken: pageToken)
		if itemList.nextPageToken == nil {
			try cache.clearCache(for: cloudPath)
		}
		return itemList
	}

	private func fillCache(for cloudPath: CloudPath) async throws {
		try cache.clearCache(for: cloudPath)
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = securityScopedAccess.start(url)
		defer {
			if shouldStopAccessing {
				securityScopedAccess.stop(url)
			}
		}
		CloudAccessDDLogDebug("LocalFileSystemProvider: fillCache(for: \(cloudPath.path)) called with startAccessingSecurityScopedResource: \(shouldStopAccessing)")
		let readingIntent = NSFileAccessIntent.readingIntent(with: url)
		let childURLs: [URL] = try await withSDKContinuation { resumer in
			coordinate(with: readingIntent) { error in
				if let error {
					CloudAccessDDLogDebug("LocalFileSystemProvider: fillCache(for: \(cloudPath.path)) failed coordinated read with error: \(error)")
					resumer.resume(throwing: error)
					return
				}
				do {
					try self.evaluateReadingIntentForFetchItemList(readingIntent)
				} catch {
					CloudAccessDDLogDebug("LocalFileSystemProvider: fillCache(for: \(cloudPath.path)) failed readingIntent evaluation with error: \(error)")
					resumer.resume(throwing: error)
					return
				}
				guard let directoryEnumerator = FileManager.default.enumerator(at: readingIntent.url, includingPropertiesForKeys: [.isHiddenKey], options: .skipsSubdirectoryDescendants) else {
					CloudAccessDDLogDebug("LocalFileSystemProvider: fillCache(for: \(cloudPath.path)) failed directoryEnumerator creation")
					resumer.resume(throwing: CloudProviderError.pageTokenInvalid)
					return
				}
				resumer.resume(returning: directoryEnumerator.compactMap { $0 as? URL })
			}
		}
		try await fillCacheAfterCheck(for: cloudPath, url: url, childURLs: childURLs)
	}

	private func evaluateReadingIntentForFetchItemList(_ readingIntent: NSFileAccessIntent) throws {
		do {
			let attributes = try readingIntent.url.promisedItemResourceValues(forKeys: [.isDirectoryKey])
			guard attributes.isDirectory ?? false else {
				throw CloudProviderError.itemTypeMismatch
			}
		} catch CocoaError.fileReadNoSuchFile {
			throw CloudProviderError.itemNotFound
		} catch CocoaError.fileReadNoPermission {
			throw CloudProviderError.unauthorized
		}
	}

	private func fillCacheAfterCheck(for cloudPath: CloudPath, url: URL, childURLs: [URL]) async throws {
		do {
			var cachedItemsCount: Int64 = 0
			for childURL in childURLs {
				try Task.checkCancellation()
				guard !childURL.isHidden || FileManager.default.isUbiquitousItem(at: childURL) else {
					continue
				}
				let iCloudCompatibleChildURL = url.appendingPathComponent(getItemName(forItemAt: childURL))
				guard iCloudCompatibleChildURL.lastPathComponent.prefix(1) != "." else {
					continue
				}
				do {
					let childItemMetadata = try await getItemMetadata(forItemAt: iCloudCompatibleChildURL, parentCloudPath: cloudPath)
					cachedItemsCount += 1
					try cache.save(childItemMetadata, for: cloudPath, index: cachedItemsCount)
				} catch CloudProviderError.itemNotFound {
					// Ignore item that can't be found anyway, this should not prevent fetching item list
				}
			}
			CloudAccessDDLogDebug("LocalFileSystemProvider: fillCache(for: \(cloudPath.path)) finished")
		} catch {
			CloudAccessDDLogDebug("LocalFileSystemProvider: fillCache(for: \(cloudPath.path)) failed with error: \(error)")
			throw error
		}
	}

	private func getCachedElements(for cloudPath: CloudPath, pageToken: String?) throws -> CloudItemList {
		let cacheResponse = try cache.getResponse(for: cloudPath, pageToken: pageToken)
		return CloudItemList(items: cacheResponse.elements, nextPageToken: cacheResponse.nextPageToken)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = securityScopedAccess.start(url)
		defer {
			if shouldStopAccessing {
				securityScopedAccess.stop(url)
			}
		}
		CloudAccessDDLogDebug("LocalFileSystemProvider: downloadFile(from: \(cloudPath.path) to: \(localURL)) called with startAccessingSecurityScopedResource: \(shouldStopAccessing)")
		let phases = Progress.phases(of: progress, 999)
		let readingIntent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
		let metadata = try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			try await withSDKContinuation { (resumer: Resumer<CloudItemMetadata>) in
				coordinate(with: readingIntent) { error in
					if let error {
						CloudAccessDDLogDebug("LocalFileSystemProvider: downloadFile(from: \(cloudPath.path) to: \(localURL)) failed coordinated read with error: \(error)")
						resumer.resume(throwing: error)
						return
					}
					do {
						guard try self.validateItemType(at: readingIntent.url, with: .file) else {
							throw CloudProviderError.itemTypeMismatch
						}
						// The modification date is read before the content is copied, so that it's never newer than the copy
						let sourceMetadata = try self.readItemMetadata(forItemAt: url, coordinatedURL: readingIntent.url, parentCloudPath: cloudPath.deletingLastPathComponent())
						try FileManager.default.copyItem(at: readingIntent.url, to: stagedFile)
						resumer.resume(returning: sourceMetadata)
					} catch CocoaError.fileReadNoSuchFile {
						CloudAccessDDLogDebug("LocalFileSystemProvider: downloadFile(from: \(cloudPath.path) to: \(localURL)) failed with fileReadNoSuchFile")
						resumer.resume(throwing: CloudProviderError.itemNotFound)
					} catch CocoaError.fileReadNoPermission {
						CloudAccessDDLogDebug("LocalFileSystemProvider: downloadFile(from: \(cloudPath.path) to: \(localURL)) failed with fileReadNoPermission")
						resumer.resume(throwing: CloudProviderError.unauthorized)
					} catch {
						CloudAccessDDLogDebug("LocalFileSystemProvider: downloadFile(from: \(cloudPath.path) to: \(localURL)) failed with error: \(error)")
						resumer.resume(throwing: error)
					}
				}
			}
		})
		CloudAccessDDLogDebug("LocalFileSystemProvider: downloadFile(from: \(cloudPath.path) to: \(localURL)) finished")
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = securityScopedAccess.start(url)
		defer {
			if shouldStopAccessing {
				securityScopedAccess.stop(url)
			}
		}
		CloudAccessDDLogDebug("LocalFileSystemProvider: uploadFile(from: \(localURL) to: \(cloudPath.path), replaceExisting: \(replaceExisting)) called with startAccessingSecurityScopedResource: \(shouldStopAccessing)")
		let phases = Progress.phases(of: progress, 999)
		let writingIntent = NSFileAccessIntent.writingIntent(with: url, options: replaceExisting ? .forReplacing : [])
		try await withSDKContinuation { (resumer: Resumer<Void>) in
			coordinate(with: writingIntent) { error in
				if let error {
					CloudAccessDDLogDebug("LocalFileSystemProvider: uploadFile(from: \(localURL) to: \(cloudPath.path), replaceExisting: \(replaceExisting)) failed coordinated write with error: \(error)")
					resumer.resume(throwing: error)
					return
				}
				do {
					try self.validateAndCopyFile(from: localURL, to: writingIntent.url, replaceExisting: replaceExisting)
					CloudAccessDDLogDebug("LocalFileSystemProvider: uploadFile(from: \(localURL) to: \(cloudPath.path), replaceExisting: \(replaceExisting)) finished, getting metadata…")
					resumer.resume()
				} catch CocoaError.fileReadNoSuchFile {
					CloudAccessDDLogDebug("LocalFileSystemProvider: uploadFile(from: \(localURL) to: \(cloudPath.path), replaceExisting: \(replaceExisting)) failed with fileReadNoSuchFile")
					resumer.resume(throwing: CloudProviderError.itemNotFound)
				} catch CocoaError.fileWriteFileExists {
					CloudAccessDDLogDebug("LocalFileSystemProvider: uploadFile(from: \(localURL) to: \(cloudPath.path), replaceExisting: \(replaceExisting)) failed with fileWriteFileExists")
					resumer.resume(throwing: CloudProviderError.itemAlreadyExists)
				} catch CocoaError.fileNoSuchFile {
					CloudAccessDDLogDebug("LocalFileSystemProvider: uploadFile(from: \(localURL) to: \(cloudPath.path), replaceExisting: \(replaceExisting)) failed with fileNoSuchFile")
					resumer.resume(throwing: CloudProviderError.parentFolderDoesNotExist)
				} catch CocoaError.fileWriteOutOfSpace {
					CloudAccessDDLogDebug("LocalFileSystemProvider: uploadFile(from: \(localURL) to: \(cloudPath.path), replaceExisting: \(replaceExisting)) failed with fileWriteOutOfSpace")
					resumer.resume(throwing: CloudProviderError.quotaInsufficient)
				} catch CocoaError.fileReadNoPermission {
					CloudAccessDDLogDebug("LocalFileSystemProvider: uploadFile(from: \(localURL) to: \(cloudPath.path), replaceExisting: \(replaceExisting)) failed with fileReadNoPermission")
					resumer.resume(throwing: CloudProviderError.unauthorized)
				} catch {
					CloudAccessDDLogDebug("LocalFileSystemProvider: uploadFile(from: \(localURL) to: \(cloudPath.path), replaceExisting: \(replaceExisting)) failed with error: \(error)")
					resumer.resume(throwing: error)
				}
			}
		}
		let metadata = try await getItemMetadata(forItemAt: url, parentCloudPath: cloudPath.deletingLastPathComponent())
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = securityScopedAccess.start(url)
		defer {
			if shouldStopAccessing {
				securityScopedAccess.stop(url)
			}
		}
		CloudAccessDDLogDebug("LocalFileSystemProvider: createFolder(at: \(cloudPath.path)) called with startAccessingSecurityScopedResource: \(shouldStopAccessing)")
		let writingIntent = NSFileAccessIntent.writingIntent(with: url, options: [])
		try await withSDKContinuation { (resumer: Resumer<Void>) in
			coordinate(with: writingIntent) { error in
				if let error {
					CloudAccessDDLogDebug("LocalFileSystemProvider: createFolder(at: \(cloudPath.path)) failed coordinated write with error: \(error)")
					resumer.resume(throwing: error)
					return
				}
				do {
					try FileManager.default.createDirectory(at: writingIntent.url, withIntermediateDirectories: false, attributes: nil)
					CloudAccessDDLogDebug("LocalFileSystemProvider: createFolder(at: \(cloudPath.path)) finished")
					resumer.resume()
				} catch CocoaError.fileWriteFileExists {
					CloudAccessDDLogDebug("LocalFileSystemProvider: createFolder(at: \(cloudPath.path)) failed with fileWriteFileExists")
					resumer.resume(throwing: CloudProviderError.itemAlreadyExists)
				} catch CocoaError.fileNoSuchFile {
					CloudAccessDDLogDebug("LocalFileSystemProvider: createFolder(at: \(cloudPath.path)) failed with fileNoSuchFile")
					resumer.resume(throwing: CloudProviderError.parentFolderDoesNotExist)
				} catch CocoaError.fileWriteOutOfSpace {
					CloudAccessDDLogDebug("LocalFileSystemProvider: createFolder(at: \(cloudPath.path)) failed with fileWriteOutOfSpace")
					resumer.resume(throwing: CloudProviderError.quotaInsufficient)
				} catch CocoaError.fileReadNoPermission {
					CloudAccessDDLogDebug("LocalFileSystemProvider: createFolder(at: \(cloudPath.path)) failed with fileReadNoPermission")
					resumer.resume(throwing: CloudProviderError.unauthorized)
				} catch {
					CloudAccessDDLogDebug("LocalFileSystemProvider: createFolder(at: \(cloudPath.path)) failed with error: \(error)")
					resumer.resume(throwing: error)
				}
			}
		}
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
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = securityScopedAccess.start(url)
		defer {
			if shouldStopAccessing {
				securityScopedAccess.stop(url)
			}
		}
		CloudAccessDDLogDebug("LocalFileSystemProvider: deleteItem(at: \(cloudPath.path)) called with startAccessingSecurityScopedResource: \(shouldStopAccessing)")
		let writingIntent = NSFileAccessIntent.writingIntent(with: url, options: .forDeleting)
		try await withSDKContinuation { (resumer: Resumer<Void>) in
			coordinate(with: writingIntent) { error in
				if let error {
					CloudAccessDDLogDebug("LocalFileSystemProvider: deleteItem(at: \(cloudPath.path)) failed coordinated write with error: \(error)")
					resumer.resume(throwing: error)
					return
				}
				do {
					try FileManager.default.removeItem(at: writingIntent.url)
					CloudAccessDDLogDebug("LocalFileSystemProvider: deleteItem(at: \(cloudPath.path)) finished")
					resumer.resume()
				} catch CocoaError.fileNoSuchFile {
					CloudAccessDDLogDebug("LocalFileSystemProvider: deleteItem(at: \(cloudPath.path)) failed with fileNoSuchFile")
					resumer.resume(throwing: CloudProviderError.itemNotFound)
				} catch CocoaError.fileReadNoPermission {
					CloudAccessDDLogDebug("LocalFileSystemProvider: deleteItem(at: \(cloudPath.path)) failed with fileReadNoPermission")
					resumer.resume(throwing: CloudProviderError.unauthorized)
				} catch {
					CloudAccessDDLogDebug("LocalFileSystemProvider: deleteItem(at: \(cloudPath.path)) failed with error: \(error)")
					resumer.resume(throwing: error)
				}
			}
		}
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
		let sourceURL = rootURL.appendingPathComponent(sourceCloudPath)
		let targetURL = rootURL.appendingPathComponent(targetCloudPath)
		let shouldStopAccessing = securityScopedAccess.start(sourceURL)
		defer {
			if shouldStopAccessing {
				securityScopedAccess.stop(sourceURL)
			}
		}
		CloudAccessDDLogDebug("LocalFileSystemProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) called with startAccessingSecurityScopedResource: \(shouldStopAccessing)")
		let writingIntent = NSFileAccessIntent.writingIntent(with: sourceURL, options: .forMoving)
		try await withSDKContinuation { (resumer: Resumer<Void>) in
			coordinate(with: writingIntent) { error in
				if let error {
					CloudAccessDDLogDebug("LocalFileSystemProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed coordinated write with error: \(error)")
					resumer.resume(throwing: error)
					return
				}
				do {
					try FileManager.default.moveItem(at: writingIntent.url, to: targetURL)
					CloudAccessDDLogDebug("LocalFileSystemProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) finished")
					resumer.resume()
				} catch CocoaError.fileNoSuchFile {
					CloudAccessDDLogDebug("LocalFileSystemProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with fileNoSuchFile")
					if FileManager.default.fileExists(atPath: targetURL.deletingLastPathComponent().path) {
						resumer.resume(throwing: CloudProviderError.itemNotFound)
					} else {
						resumer.resume(throwing: CloudProviderError.parentFolderDoesNotExist)
					}
				} catch CocoaError.fileWriteFileExists {
					CloudAccessDDLogDebug("LocalFileSystemProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with fileWriteFileExists")
					resumer.resume(throwing: CloudProviderError.itemAlreadyExists)
				} catch CocoaError.fileWriteOutOfSpace {
					CloudAccessDDLogDebug("LocalFileSystemProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with fileWriteOutOfSpace")
					resumer.resume(throwing: CloudProviderError.quotaInsufficient)
				} catch CocoaError.fileReadNoPermission {
					CloudAccessDDLogDebug("LocalFileSystemProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with fileReadNoPermission")
					resumer.resume(throwing: CloudProviderError.unauthorized)
				} catch {
					CloudAccessDDLogDebug("LocalFileSystemProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with error: \(error)")
					resumer.resume(throwing: error)
				}
			}
		}
	}

	// MARK: - Internal

	/// Uses a file coordinator per access, because accesses through the same file coordinator never wait for each other.
	private func coordinate(with intent: NSFileAccessIntent, byAccessor accessor: @escaping @Sendable (Error?) -> Void) {
		NSFileCoordinator().coordinate(with: [intent], queue: queue, byAccessor: accessor)
	}

	private func getItemType(from url: URL) throws -> CloudItemType {
		let attributes: [FileAttributeKey: Any]
		do {
			attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		} catch CocoaError.fileReadUnknown {
			throw CloudProviderError.itemNotFound
		}
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

	func getItemName(forItemAt url: URL) -> String {
		CloudAccessDDLogDebug("LocalFileSystemProvider: getItemName(forItemAt: \(url)) called")
		let name = url.lastPathComponent
		// Workaround for files with a `_` prefix. Usually, the pattern for iCloud Drive placeholder files is `.<name>.icloud` but files with a `_` prefix in their original name have two dots in the beginning when they are offloaded.
		// See: https://github.com/cryptomator/cloud-access-swift/issues/19
		// swiftlint:disable:next force_try
		let regex = try! NSRegularExpression(pattern: #"^\.+(.*)\.icloud$"#, options: [])
		let range = NSRange(name.startIndex ..< name.endIndex, in: name)
		guard let match = regex.firstMatch(in: name, options: [], range: range), let matchedRange = Range(match.range(at: 1), in: name) else {
			return name
		}
		return String(name[matchedRange])
	}

	/// Doesn't check for cancellation, so that an upload can still fetch the metadata to return after its change.
	private func getItemMetadata(forItemAt url: URL, parentCloudPath: CloudPath) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("LocalFileSystemProvider: getItemMetadata(forItemAt: \(url), parentCloudPath: \(parentCloudPath.path)) called")
		let readingIntent = NSFileAccessIntent.readingIntent(with: url, options: .immediatelyAvailableMetadataOnly)
		return try await withSDKContinuation { resumer in
			coordinate(with: readingIntent) { error in
				if let error {
					CloudAccessDDLogDebug("LocalFileSystemProvider: getItemMetadata(forItemAt: \(url), parentCloudPath: \(parentCloudPath.path)) failed coordinated read with error: \(error)")
					resumer.resume(throwing: error)
					return
				}
				do {
					try resumer.resume(returning: self.readItemMetadata(forItemAt: url, coordinatedURL: readingIntent.url, parentCloudPath: parentCloudPath))
				} catch CocoaError.fileReadNoSuchFile {
					CloudAccessDDLogDebug("LocalFileSystemProvider: getItemMetadata(forItemAt: \(url), parentCloudPath: \(parentCloudPath.path)) failed with fileReadNoSuchFile")
					resumer.resume(throwing: CloudProviderError.itemNotFound)
				} catch CocoaError.fileReadNoPermission {
					CloudAccessDDLogDebug("LocalFileSystemProvider: getItemMetadata(forItemAt: \(url), parentCloudPath: \(parentCloudPath.path)) failed with fileReadNoPermission")
					resumer.resume(throwing: CloudProviderError.unauthorized)
				} catch {
					CloudAccessDDLogDebug("LocalFileSystemProvider: getItemMetadata(forItemAt: \(url), parentCloudPath: \(parentCloudPath.path)) failed with error: \(error)")
					resumer.resume(throwing: error)
				}
			}
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
		guard try validateItemType(at: sourceURL, with: .file) else {
			throw CloudProviderError.itemTypeMismatch
		}
		if replaceExisting {
			do {
				guard try validateItemType(at: targetURL, with: .file) else {
					throw CloudProviderError.itemAlreadyExists
				}
			} catch CocoaError.fileReadNoSuchFile {
				// no-op
			}
			try FileManager.default.copyItemWithOverwrite(at: sourceURL, to: targetURL)
		} else {
			try FileManager.default.copyItem(at: sourceURL, to: targetURL)
		}
	}
}

private extension URL {
	var isHidden: Bool {
		return (try? resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
	}
}
