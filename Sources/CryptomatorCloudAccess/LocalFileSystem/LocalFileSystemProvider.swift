//
//  LocalFileSystemProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Wahid Ali on 27.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import Promises

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
public class LocalFileSystemProvider: CloudProvider {
	private let fileManager = FileManager()
	private let rootURL: URL
	private let queue = OperationQueue()
	private let shouldStopAccessingRootURL: Bool
	private lazy var fileCoordinator = NSFileCoordinator()
	private let maxPageSize: Int
	private let cache: DirectoryContentCache
	private let tmpDirURL: URL

	public init(rootURL: URL, maxPageSize: Int = .max) throws {
		precondition(rootURL.isFileURL)
		self.rootURL = rootURL
		self.shouldStopAccessingRootURL = rootURL.startAccessingSecurityScopedResource()
		self.maxPageSize = maxPageSize
		self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		let dbURL = tmpDirURL.appendingPathComponent("db.sqlite")
		self.cache = try DirectoryContentDBCache(dbWriter: try DatabaseQueue(path: dbURL.path), maxPageSize: maxPageSize)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
		if shouldStopAccessingRootURL {
			rootURL.stopAccessingSecurityScopedResource()
		}
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = url.startAccessingSecurityScopedResource()
		return getItemMetadata(forItemAt: url, parentCloudPath: cloudPath.deletingLastPathComponent()).always {
			if shouldStopAccessing {
				url.stopAccessingSecurityScopedResource()
			}
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let initialPromise: Promise<Void>
		if pageToken != nil {
			initialPromise = Promise(())
		} else {
			initialPromise = fillCache(for: cloudPath)
		}
		return initialPromise.then {
			self.getCachedElements(for: cloudPath, pageToken: pageToken)
		}.then { itemList -> CloudItemList in
			if itemList.nextPageToken == nil {
				try self.cache.clearCache(for: cloudPath)
			}
			return itemList
		}
	}

	private func fillCache(for cloudPath: CloudPath) -> Promise<Void> {
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = url.startAccessingSecurityScopedResource()
		let promise = Promise<Void>.pending().always {
			if shouldStopAccessing {
				url.stopAccessingSecurityScopedResource()
			}
		}
		let readingIntent = NSFileAccessIntent.readingIntent(with: url, options: .immediatelyAvailableMetadataOnly)
		fileCoordinator.coordinate(with: [readingIntent], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				try self.evaluateReadingIntentForFetchItemList(readingIntent)
			} catch {
				promise.reject(error)
				return
			}
			guard let directoryEnumerator = FileManager.default.enumerator(at: readingIntent.url, includingPropertiesForKeys: [.isHiddenKey], options: .skipsSubdirectoryDescendants) else {
				promise.reject(CloudProviderError.pageTokenInvalid)
				return
			}
			DispatchQueue.global().async {
				var cachedItemsCount: Int64 = 0
				for case let childURL as URL in directoryEnumerator {
					autoreleasepool {
						guard !childURL.isHidden || self.fileManager.isUbiquitousItem(at: childURL) else {
							return
						}
						let iCloudCompatibleChildURL = url.appendingPathComponent(self.getItemName(forItemAt: childURL))
						guard iCloudCompatibleChildURL.lastPathComponent.prefix(1) != "." else {
							return
						}
						do {
							let childItemMetadata = try awaitPromise(self.getItemMetadata(forItemAt: iCloudCompatibleChildURL, parentCloudPath: cloudPath))
							cachedItemsCount += 1
							try self.cache.save(childItemMetadata, for: cloudPath, index: cachedItemsCount)
						} catch {
							promise.reject(error)
							return
						}
					}
				}
				promise.fulfill(())
			}
		}
		return promise
	}

	private func evaluateReadingIntentForFetchItemList(_ readingIntent: NSFileAccessIntent) throws {
		do {
			let attributes = try readingIntent.url.promisedItemResourceValues(forKeys: [.nameKey, .fileSizeKey, .contentModificationDateKey, .fileResourceTypeKey])
			let itemType = getItemType(from: attributes.fileResourceType)
			guard itemType == .folder else {
				throw CloudProviderError.itemTypeMismatch
			}
		} catch CocoaError.fileReadNoSuchFile {
			throw CloudProviderError.itemNotFound
		} catch CocoaError.fileReadNoPermission {
			throw CloudProviderError.unauthorized
		}
	}

	private func getCachedElements(for cloudPath: CloudPath, pageToken: String?) -> Promise<CloudItemList> {
		let cacheResponse: DirectoryContentCacheResponse
		do {
			cacheResponse = try cache.getResponse(for: cloudPath, pageToken: pageToken)
		} catch {
			return Promise(error)
		}
		return Promise(CloudItemList(items: cacheResponse.elements, nextPageToken: cacheResponse.nextPageToken))
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = url.startAccessingSecurityScopedResource()
		let promise = Promise<Void>.pending().always {
			if shouldStopAccessing {
				url.stopAccessingSecurityScopedResource()
			}
		}
		let readingIntent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
		fileCoordinator.coordinate(with: [readingIntent], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				guard try self.validateItemType(at: readingIntent.url, with: .file) else {
					promise.reject(CloudProviderError.itemTypeMismatch)
					return
				}
				try self.fileManager.copyItem(at: readingIntent.url, to: localURL)
				promise.fulfill(())
			} catch CocoaError.fileReadNoSuchFile {
				promise.reject(CloudProviderError.itemNotFound)
			} catch CocoaError.fileWriteFileExists {
				promise.reject(CloudProviderError.itemAlreadyExists)
			} catch CocoaError.fileReadNoPermission {
				promise.reject(CloudProviderError.unauthorized)
			} catch {
				promise.reject(error)
			}
		}
		return promise
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = url.startAccessingSecurityScopedResource()
		let promise = Promise<CloudItemMetadata>.pending().always {
			if shouldStopAccessing {
				url.stopAccessingSecurityScopedResource()
			}
		}
		let writingIntent = NSFileAccessIntent.writingIntent(with: url, options: replaceExisting ? .forReplacing : [])
		fileCoordinator.coordinate(with: [writingIntent], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				try self.copyFile(from: localURL, to: writingIntent.url, replaceExisting: replaceExisting)
				self.getItemMetadata(forItemAt: url, parentCloudPath: cloudPath.deletingLastPathComponent()).then { metadata in
					promise.fulfill(metadata)
				}.catch { error in
					promise.reject(error)
				}
			} catch CocoaError.fileReadNoSuchFile {
				promise.reject(CloudProviderError.itemNotFound)
			} catch CocoaError.fileWriteFileExists {
				promise.reject(CloudProviderError.itemAlreadyExists)
			} catch CocoaError.fileNoSuchFile {
				promise.reject(CloudProviderError.parentFolderDoesNotExist)
			} catch CocoaError.fileWriteOutOfSpace {
				promise.reject(CloudProviderError.quotaInsufficient)
			} catch CocoaError.fileReadNoPermission {
				promise.reject(CloudProviderError.unauthorized)
			} catch {
				promise.reject(error)
			}
		}
		return promise
	}

	private func copyFile(from sourceURL: URL, to targetURL: URL, replaceExisting: Bool) throws {
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
			try fileManager.copyItemWithOverwrite(at: sourceURL, to: targetURL)
		} else {
			try fileManager.copyItem(at: sourceURL, to: targetURL)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = url.startAccessingSecurityScopedResource()
		let promise = Promise<Void>.pending().always {
			if shouldStopAccessing {
				url.stopAccessingSecurityScopedResource()
			}
		}
		let writingIntent = NSFileAccessIntent.writingIntent(with: url, options: [])
		fileCoordinator.coordinate(with: [writingIntent], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				try self.fileManager.createDirectory(at: writingIntent.url, withIntermediateDirectories: false, attributes: nil)
				promise.fulfill(())
			} catch CocoaError.fileWriteFileExists {
				promise.reject(CloudProviderError.itemAlreadyExists)
			} catch CocoaError.fileNoSuchFile {
				promise.reject(CloudProviderError.parentFolderDoesNotExist)
			} catch CocoaError.fileWriteOutOfSpace {
				promise.reject(CloudProviderError.quotaInsufficient)
			} catch CocoaError.fileReadNoPermission {
				promise.reject(CloudProviderError.unauthorized)
			} catch {
				promise.reject(error)
			}
		}
		return promise
	}

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath)
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath)
	}

	private func deleteItem(at cloudPath: CloudPath) -> Promise<Void> {
		let url = rootURL.appendingPathComponent(cloudPath)
		let shouldStopAccessing = url.startAccessingSecurityScopedResource()
		let promise = Promise<Void>.pending().always {
			if shouldStopAccessing {
				url.stopAccessingSecurityScopedResource()
			}
		}
		let writingIntent = NSFileAccessIntent.writingIntent(with: url, options: .forDeleting)
		fileCoordinator.coordinate(with: [writingIntent], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				try self.fileManager.removeItem(at: writingIntent.url)
				promise.fulfill(())
			} catch CocoaError.fileNoSuchFile {
				promise.reject(CloudProviderError.itemNotFound)
			} catch CocoaError.fileReadNoPermission {
				promise.reject(CloudProviderError.unauthorized)
			} catch {
				promise.reject(error)
			}
		}
		return promise
	}

	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		let sourceURL = rootURL.appendingPathComponent(sourceCloudPath)
		let targetURL = rootURL.appendingPathComponent(targetCloudPath)
		let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()

		let promise = Promise<Void>.pending().always {
			if shouldStopAccessing {
				sourceURL.stopAccessingSecurityScopedResource()
			}
		}
		let writingIntent = NSFileAccessIntent.writingIntent(with: sourceURL, options: .forMoving)
		fileCoordinator.coordinate(with: [writingIntent], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				try self.fileManager.moveItem(at: writingIntent.url, to: targetURL)
				promise.fulfill(())
			} catch CocoaError.fileNoSuchFile {
				if self.fileManager.fileExists(atPath: targetURL.deletingLastPathComponent().path) {
					promise.reject(CloudProviderError.itemNotFound)
				} else {
					promise.reject(CloudProviderError.parentFolderDoesNotExist)
				}
			} catch CocoaError.fileWriteFileExists {
				promise.reject(CloudProviderError.itemAlreadyExists)
			} catch CocoaError.fileWriteOutOfSpace {
				promise.reject(CloudProviderError.quotaInsufficient)
			} catch CocoaError.fileReadNoPermission {
				promise.reject(CloudProviderError.unauthorized)
			} catch {
				promise.reject(error)
			}
		}
		return promise
	}

	// MARK: - Internal

	private func getItemType(from url: URL) throws -> CloudItemType {
		let attributes: [FileAttributeKey: Any]
		do {
			attributes = try fileManager.attributesOfItem(atPath: url.path)
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
		let name = url.lastPathComponent
		// swiftlint:disable:next force_try
		let regex = try! NSRegularExpression(pattern: #"^\.(.*)\.icloud$"#, options: [])
		let range = NSRange(name.startIndex ..< name.endIndex, in: name)

		guard let match = regex.firstMatch(in: name, options: [], range: range), let matchedRange = Range(match.range(at: 1), in: name) else {
			return name
		}
		return String(name[matchedRange])
	}

	private func getItemMetadata(forItemAt url: URL, parentCloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let promise = Promise<CloudItemMetadata>.pending()
		let readingIntent = NSFileAccessIntent.readingIntent(with: url, options: .immediatelyAvailableMetadataOnly)
		fileCoordinator.coordinate(with: [readingIntent], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				let attributes = try readingIntent.url.promisedItemResourceValues(forKeys: [.nameKey, .fileSizeKey, .contentModificationDateKey, .fileResourceTypeKey])
				let name = attributes.name ?? url.lastPathComponent
				let size = attributes.fileSize
				let lastModifiedDate = attributes.contentModificationDate
				let itemType = self.getItemType(from: attributes.fileResourceType)
				promise.fulfill(CloudItemMetadata(name: name, cloudPath: parentCloudPath.appendingPathComponent(name), itemType: itemType, lastModifiedDate: lastModifiedDate, size: size))
			} catch CocoaError.fileReadNoSuchFile {
				promise.reject(CloudProviderError.itemNotFound)
			} catch CocoaError.fileReadNoPermission {
				promise.reject(CloudProviderError.unauthorized)
			} catch {
				promise.reject(error)
			}
		}
		return promise
	}
}

private extension URL {
	var isHidden: Bool {
		return (try? resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
	}
}
