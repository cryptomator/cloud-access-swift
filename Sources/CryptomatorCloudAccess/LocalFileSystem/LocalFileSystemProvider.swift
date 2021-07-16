//
//  LocalFileSystemProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Wahid Ali on 27.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
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

 Since the local file system is not actually a cloud, the naming might be confusing. Even though this library is dedicated to provide access to many cloud storage services, access to the local file system still might be useful.
 */
public class LocalFileSystemProvider: CloudProvider {
	private let fileManager = FileManager()
	private let rootURL: URL
	private let queue = OperationQueue()

	public init(rootURL: URL) {
		precondition(rootURL.isFileURL)
		self.rootURL = rootURL
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		return getItemMetadata(forItemAt: url, parentCloudPath: cloudPath.deletingLastPathComponent()).always {
			self.rootURL.stopAccessingSecurityScopedResource()
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		guard pageToken == nil else {
			return Promise(CloudProviderError.pageTokenInvalid)
		}
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		let promise = Promise<CloudItemList>.pending().always {
			self.rootURL.stopAccessingSecurityScopedResource()
		}
		let readingIntent = NSFileAccessIntent.readingIntent(with: url, options: .immediatelyAvailableMetadataOnly)
		NSFileCoordinator().coordinate(with: [readingIntent], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				let contents = try self.fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isHiddenKey])
				let metadatas = contents.filter { childURL in
					!childURL.isHidden || self.fileManager.isUbiquitousItem(at: childURL)
				}.map { childURL in
					return url.appendingPathComponent(self.getItemName(forItemAt: childURL))
				}.filter { iCloudCompatibleChildURL in
					iCloudCompatibleChildURL.lastPathComponent.prefix(1) != "."
				}.map { iCloudCompatibleChildURL -> Promise<CloudItemMetadata> in
					return self.getItemMetadata(forItemAt: iCloudCompatibleChildURL, parentCloudPath: cloudPath)
				}
				all(metadatas).then { metadatas in
					promise.fulfill(CloudItemList(items: metadatas, nextPageToken: nil))
				}.catch { error in
					promise.reject(error)
				}
			} catch CocoaError.fileReadNoSuchFile {
				promise.reject(CloudProviderError.itemNotFound)
			} catch CocoaError.fileReadUnknown {
				promise.reject(CloudProviderError.itemTypeMismatch)
			} catch CocoaError.fileReadNoPermission {
				promise.reject(CloudProviderError.unauthorized)
			} catch {
				promise.reject(error)
			}
		}
		return promise
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		let promise = Promise<Void>.pending().always {
			self.rootURL.stopAccessingSecurityScopedResource()
		}
		NSFileCoordinator().coordinate(with: [.readingIntent(with: url, options: .withoutChanges)], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				guard try self.validateItemType(at: url, with: .file) else {
					promise.reject(CloudProviderError.itemTypeMismatch)
					return
				}
				try self.fileManager.copyItem(at: url, to: localURL)
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
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		let promise = Promise<CloudItemMetadata>.pending().always {
			self.rootURL.stopAccessingSecurityScopedResource()
		}
		NSFileCoordinator().coordinate(with: [.writingIntent(with: url, options: replaceExisting ? .forReplacing : [])], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				try self.copyFile(from: localURL, to: url, replaceExisting: replaceExisting)
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
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		let promise = Promise<Void>.pending().always {
			self.rootURL.stopAccessingSecurityScopedResource()
		}
		NSFileCoordinator().coordinate(with: [.writingIntent(with: url, options: [])], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				try self.fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
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
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		let promise = Promise<Void>.pending().always {
			self.rootURL.stopAccessingSecurityScopedResource()
		}
		let writingIntent = NSFileAccessIntent.writingIntent(with: url, options: .forDeleting)
		NSFileCoordinator().coordinate(with: [writingIntent], queue: queue) { error in
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
		guard let sourceURL = URL(cloudPath: sourceCloudPath, relativeTo: rootURL), let targetURL = URL(cloudPath: targetCloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		let promise = Promise<Void>.pending().always {
			self.rootURL.stopAccessingSecurityScopedResource()
		}
		let writingIntent = NSFileAccessIntent.writingIntent(with: sourceURL, options: .forMoving)
		NSFileCoordinator().coordinate(with: [writingIntent], queue: queue) { error in
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
		NSFileCoordinator().coordinate(with: [readingIntent], queue: queue) { error in
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
