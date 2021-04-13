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
		let promise = Promise<CloudItemMetadata>.pending().always {
			self.rootURL.stopAccessingSecurityScopedResource()
		}
		NSFileCoordinator().coordinate(with: [.readingIntent(with: url, options: .immediatelyAvailableMetadataOnly)], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				let attributes = try self.fileManager.attributesOfItem(atPath: url.path)
				let name = url.lastPathComponent
				let size = attributes[FileAttributeKey.size] as? Int
				let lastModifiedDate = attributes[FileAttributeKey.modificationDate] as? Date
				let itemType = self.getItemType(from: attributes[FileAttributeKey.type] as? FileAttributeType)
				promise.fulfill(CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size))
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

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		let promise = Promise<CloudItemList>.pending().always {
			self.rootURL.stopAccessingSecurityScopedResource()
		}
		NSFileCoordinator().coordinate(with: [.readingIntent(with: url, options: .immediatelyAvailableMetadataOnly)], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				let contents = try self.fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceTypeKey], options: .skipsHiddenFiles)
				let metadatas = contents.map { url -> CloudItemMetadata in
					let name = url.lastPathComponent
					let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
					let lastModifiedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
					let itemType = self.getItemType(from: (try? url.resourceValues(forKeys: [.fileResourceTypeKey]))?.fileResourceType)
					return CloudItemMetadata(name: name, cloudPath: cloudPath.appendingPathComponent(name), itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
				}
				promise.fulfill(CloudItemList(items: metadatas, nextPageToken: nil))
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
		let pendingUploadPromise = Promise<Void>.pending().always {
			self.rootURL.stopAccessingSecurityScopedResource()
		}
		NSFileCoordinator().coordinate(with: [.writingIntent(with: url, options: replaceExisting ? .forReplacing : [])], queue: queue) { error in
			if let error = error {
				pendingUploadPromise.reject(error)
				return
			}
			do {
				try self.copyFile(from: localURL, to: url, replaceExisting: replaceExisting, pendingPromise: pendingUploadPromise)
			} catch CocoaError.fileReadNoSuchFile {
				pendingUploadPromise.reject(CloudProviderError.itemNotFound)
			} catch CocoaError.fileWriteFileExists {
				pendingUploadPromise.reject(CloudProviderError.itemAlreadyExists)
			} catch CocoaError.fileNoSuchFile {
				pendingUploadPromise.reject(CloudProviderError.parentFolderDoesNotExist)
			} catch CocoaError.fileWriteOutOfSpace {
				pendingUploadPromise.reject(CloudProviderError.quotaInsufficient)
			} catch CocoaError.fileReadNoPermission {
				pendingUploadPromise.reject(CloudProviderError.unauthorized)
			} catch {
				pendingUploadPromise.reject(error)
			}
		}
		return pendingUploadPromise.then {
			self.fetchItemMetadata(at: cloudPath)
		}
	}

	private func copyFile(from sourceURL: URL, to targetURL: URL, replaceExisting: Bool, pendingPromise: Promise<Void>) throws {
		guard try validateItemType(at: sourceURL, with: .file) else {
			pendingPromise.reject(CloudProviderError.itemTypeMismatch)
			return
		}
		if replaceExisting {
			do {
				guard try validateItemType(at: targetURL, with: .file) else {
					pendingPromise.reject(CloudProviderError.itemTypeMismatch)
					return
				}
			} catch CocoaError.fileReadNoSuchFile {
				// no-op
			}
			try fileManager.copyItemWithOverwrite(at: sourceURL, to: targetURL)
			pendingPromise.fulfill(())
		} else {
			try fileManager.copyItem(at: sourceURL, to: targetURL)
			pendingPromise.fulfill(())
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
		NSFileCoordinator().coordinate(with: [.writingIntent(with: url, options: .forDeleting)], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				try self.fileManager.removeItem(at: url)
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
		NSFileCoordinator().coordinate(with: [.writingIntent(with: sourceURL, options: .forMoving)], queue: queue) { error in
			if let error = error {
				promise.reject(error)
				return
			}
			do {
				try self.fileManager.moveItem(at: sourceURL, to: targetURL)
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
}
