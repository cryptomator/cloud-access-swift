//
//  LocalFileSystemProvider.swift
//  CloudAccess
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
		defer { rootURL.stopAccessingSecurityScopedResource() }
		var promise: Promise<CloudItemMetadata>?
		var error: NSError?
		NSFileCoordinator().coordinate(readingItemAt: url, options: .immediatelyAvailableMetadataOnly, error: &error) { url in
			do {
				let attributes = try fileManager.attributesOfItem(atPath: url.path)
				let name = url.lastPathComponent
				let size = attributes[FileAttributeKey.size] as? Int
				let lastModifiedDate = attributes[FileAttributeKey.modificationDate] as? Date
				let itemType = getItemType(from: attributes[FileAttributeKey.type] as? FileAttributeType)
				guard validateItemType(at: url, with: itemType) else {
					promise = Promise(CloudProviderError.itemTypeMismatch)
					return
				}
				promise = Promise(CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size))
			} catch CocoaError.fileReadNoSuchFile {
				promise = Promise(CloudProviderError.itemNotFound)
			} catch {
				promise = Promise(error)
			}
		}
		if let error = error {
			return Promise(error)
		} else if let promise = promise {
			return promise
		} else {
			return Promise(LocalFileSystemProviderError.invalidState)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		precondition(cloudPath.hasDirectoryPath)
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer { rootURL.stopAccessingSecurityScopedResource() }
		var promise: Promise<CloudItemList>?
		var error: NSError?
		NSFileCoordinator().coordinate(readingItemAt: url, options: .immediatelyAvailableMetadataOnly, error: &error) { url in
			do {
				let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceTypeKey], options: .skipsHiddenFiles)
				let metadatas = contents.map { url -> CloudItemMetadata in
					let name = url.lastPathComponent
					let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
					let lastModifiedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
					let itemType = getItemType(from: (try? url.resourceValues(forKeys: [.fileResourceTypeKey]))?.fileResourceType)
					return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
				}
				promise = Promise(CloudItemList(items: metadatas, nextPageToken: nil))
			} catch CocoaError.fileReadNoSuchFile {
				promise = Promise(CloudProviderError.itemNotFound)
			} catch CocoaError.fileReadUnknown {
				promise = Promise(CloudProviderError.itemTypeMismatch)
			} catch {
				promise = Promise(error)
			}
		}
		if let error = error {
			return Promise(error)
		} else if let promise = promise {
			return promise
		} else {
			return Promise(LocalFileSystemProviderError.invalidState)
		}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		precondition(!cloudPath.hasDirectoryPath)
		precondition(!localURL.hasDirectoryPath)
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer { rootURL.stopAccessingSecurityScopedResource() }
		var promise: Promise<Void>?
		var error: NSError?
		NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { url in
			do {
				guard try validateItemType(at: url) else {
					promise = Promise(CloudProviderError.itemTypeMismatch)
					return
				}
				try fileManager.copyItem(at: url, to: localURL)
				promise = Promise(())
			} catch CocoaError.fileReadNoSuchFile {
				promise = Promise(CloudProviderError.itemNotFound)
			} catch CocoaError.fileWriteFileExists {
				promise = Promise(CloudProviderError.itemAlreadyExists)
			} catch {
				promise = Promise(error)
			}
		}
		if let error = error {
			return Promise(error)
		} else if let promise = promise {
			return promise
		} else {
			return Promise(LocalFileSystemProviderError.invalidState)
		}
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		precondition(!cloudPath.hasDirectoryPath)
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer { rootURL.stopAccessingSecurityScopedResource() }
		var promise: Promise<CloudItemMetadata>?
		var error: NSError?
		NSFileCoordinator().coordinate(writingItemAt: url, options: replaceExisting ? .forReplacing : [], error: &error) { url in
			do {
				guard try validateItemType(at: localURL) else {
					promise = Promise(CloudProviderError.itemTypeMismatch)
					return
				}
				if replaceExisting {
					do {
						guard try validateItemType(at: url) else {
							promise = Promise(CloudProviderError.itemTypeMismatch)
							return
						}
					} catch CocoaError.fileReadNoSuchFile {
						// no-op
					}
					try fileManager.copyItemWithOverwrite(at: localURL, to: url)
				} else {
					try fileManager.copyItem(at: localURL, to: url)
				}
			} catch CocoaError.fileReadNoSuchFile {
				promise = Promise(CloudProviderError.itemNotFound)
			} catch CocoaError.fileWriteFileExists {
				promise = Promise(CloudProviderError.itemAlreadyExists)
			} catch CocoaError.fileNoSuchFile {
				promise = Promise(CloudProviderError.parentFolderDoesNotExist)
			} catch CocoaError.fileWriteOutOfSpace {
				promise = Promise(CloudProviderError.quotaInsufficient)
			} catch {
				promise = Promise(error)
			}
		}
		if let error = error {
			return Promise(error)
		} else if let promise = promise {
			return promise
		} else {
			return fetchItemMetadata(at: cloudPath)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		precondition(cloudPath.hasDirectoryPath)
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer { rootURL.stopAccessingSecurityScopedResource() }
		var promise: Promise<Void>?
		var error: NSError?
		NSFileCoordinator().coordinate(writingItemAt: url, error: &error) { url in
			do {
				try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
				promise = Promise(())
			} catch CocoaError.fileWriteFileExists {
				promise = Promise(CloudProviderError.itemAlreadyExists)
			} catch CocoaError.fileNoSuchFile {
				promise = Promise(CloudProviderError.parentFolderDoesNotExist)
			} catch CocoaError.fileWriteOutOfSpace {
				promise = Promise(CloudProviderError.quotaInsufficient)
			} catch {
				promise = Promise(error)
			}
		}
		if let error = error {
			return Promise(error)
		} else if let promise = promise {
			return promise
		} else {
			return Promise(LocalFileSystemProviderError.invalidState)
		}
	}

	public func deleteItem(at cloudPath: CloudPath) -> Promise<Void> {
		guard let url = URL(cloudPath: cloudPath, relativeTo: rootURL) else {
			return Promise(LocalFileSystemProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer { rootURL.stopAccessingSecurityScopedResource() }
		var promise: Promise<Void>?
		var error: NSError?
		NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { url in
			do {
				guard try validateItemType(at: url) else {
					promise = Promise(CloudProviderError.itemTypeMismatch)
					return
				}
				try fileManager.removeItem(at: url)
				promise = Promise(())
			} catch CocoaError.fileReadNoSuchFile {
				promise = Promise(CloudProviderError.itemNotFound)
			} catch {
				promise = Promise(error)
			}
		}
		if let error = error {
			return Promise(error)
		} else if let promise = promise {
			return promise
		} else {
			return Promise(LocalFileSystemProviderError.invalidState)
		}
	}

	public func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		precondition(sourceCloudPath.hasDirectoryPath == targetCloudPath.hasDirectoryPath)
		guard let sourceURL = URL(cloudPath: sourceCloudPath, relativeTo: rootURL), let targetURL = URL(cloudPath: targetCloudPath, relativeTo: rootURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		guard rootURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer { rootURL.stopAccessingSecurityScopedResource() }
		var promise: Promise<Void>?
		var error: NSError?
		NSFileCoordinator().coordinate(writingItemAt: sourceURL, options: .forMoving, error: &error) { sourceURL in
			do {
				guard try validateItemType(at: sourceURL) else {
					promise = Promise(CloudProviderError.itemTypeMismatch)
					return
				}
				try fileManager.moveItem(at: sourceURL, to: targetURL)
				promise = Promise(())
			} catch CocoaError.fileReadNoSuchFile {
				promise = Promise(CloudProviderError.itemNotFound)
			} catch CocoaError.fileWriteFileExists {
				promise = Promise(CloudProviderError.itemAlreadyExists)
			} catch CocoaError.fileNoSuchFile {
				promise = Promise(CloudProviderError.parentFolderDoesNotExist)
			} catch CocoaError.fileWriteOutOfSpace {
				promise = Promise(CloudProviderError.quotaInsufficient)
			} catch {
				promise = Promise(error)
			}
		}
		if let error = error {
			return Promise(error)
		} else if let promise = promise {
			return promise
		} else {
			return Promise(LocalFileSystemProviderError.invalidState)
		}
	}

	// MARK: - Internal

	private func getItemType(at localURL: URL) throws -> CloudItemType {
		let attributes = try fileManager.attributesOfItem(atPath: localURL.path)
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

	private func validateItemType(at localURL: URL) throws -> Bool {
		let itemType = try getItemType(at: localURL)
		return validateItemType(at: localURL, with: itemType)
	}

	private func validateItemType(at url: URL, with itemType: CloudItemType) -> Bool {
		return url.hasDirectoryPath == (itemType == .folder) || !url.hasDirectoryPath == (itemType == .file)
	}
}
