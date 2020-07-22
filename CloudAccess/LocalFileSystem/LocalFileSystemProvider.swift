//
//  LocalFileSystemProvider.swift
//  CloudAccess
//
//  Created by Wahid Ali on 27.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

private extension FileManager {
	func copyItemWithOverwrite(at srcURL: URL, to dstURL: URL) throws {
		let tmpDstURL = dstURL.appendingPathExtension(UUID().uuidString)
		try moveItem(at: dstURL, to: tmpDstURL)
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
	let fileManager = FileManager()
	let startURL: URL
	public init(startURL: URL) {
		self.startURL = startURL
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata> {
		precondition(remoteURL.isFileURL)
		guard startURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer {
			remoteURL.stopAccessingSecurityScopedResource()
		}
		var name: String!
		var size: Int!
		var lastModifiedDate: Date!
		var itemType: CloudItemType!
		var err: NSError?
		var providerErr: CloudProviderError?
		NSFileCoordinator().coordinate(readingItemAt: remoteURL, options: .withoutChanges, error: nil) { readingURL in
			do {
				let attributes = try fileManager.attributesOfItem(atPath: readingURL.path)
				name = readingURL.lastPathComponent
				size = attributes[FileAttributeKey.size] as? Int
				lastModifiedDate = attributes[FileAttributeKey.modificationDate] as? Date
				itemType = getItemType(from: attributes[FileAttributeKey.type] as? FileAttributeType)
			} catch CocoaError.fileReadNoSuchFile {
				providerErr = CloudProviderError.itemNotFound
			} catch {
				err = error as NSError
			}
		}
		if let notNilProviderErr = providerErr {
			return Promise(notNilProviderErr)
		} else if let notNilErr = err {
			return Promise(notNilErr)
		}

		guard validateItemType(at: remoteURL, with: itemType) else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		return Promise(CloudItemMetadata(name: name, remoteURL: remoteURL, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size))
	}

	public func fetchItemList(forFolderAt remoteURL: URL, withPageToken _: String?) -> Promise<CloudItemList> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		guard remoteURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer {
			remoteURL.stopAccessingSecurityScopedResource()
		}
		var contents: [URL]?
		var err: NSError?
		var providerErr: CloudProviderError?
		NSFileCoordinator().coordinate(readingItemAt: remoteURL, options: .withoutChanges, error: nil) { readingURL in
			do {
				contents = try fileManager.contentsOfDirectory(at: readingURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceTypeKey], options: .skipsHiddenFiles)
			} catch CocoaError.fileReadNoSuchFile {
				providerErr = CloudProviderError.itemNotFound
			} catch CocoaError.fileReadUnknown {
				providerErr = CloudProviderError.itemTypeMismatch
			} catch {
				err = error as NSError
			}
		}
		if let notNilProviderErr = providerErr {
			return Promise(notNilProviderErr)
		} else if let notNilErr = err {
			return Promise(notNilErr)
		}
		var metadatas: [CloudItemMetadata]
		metadatas = contents!.map { url -> CloudItemMetadata in
			let name = url.lastPathComponent
			let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
			let lastModifiedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
			let itemType = getItemType(from: (try? url.resourceValues(forKeys: [.fileResourceTypeKey]))?.fileResourceType)
			return CloudItemMetadata(name: name, remoteURL: url, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
		}
		return Promise(CloudItemList(items: metadatas, nextPageToken: nil))
	}

	public func downloadFile(from remoteURL: URL, to localURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(localURL.isFileURL)
		precondition(!remoteURL.hasDirectoryPath)
		precondition(!localURL.hasDirectoryPath)
		guard localURL.startAccessingSecurityScopedResource(), remoteURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer {
			localURL.stopAccessingSecurityScopedResource()
			remoteURL.stopAccessingSecurityScopedResource()
		}
		do {
			guard try validateItemType(at: remoteURL) else {
				return Promise(CloudProviderError.itemTypeMismatch)
			}
		} catch {
			return Promise(error)
		}
		var err: NSError?
		var providerErr: CloudProviderError?
		NSFileCoordinator().coordinate(readingItemAt: remoteURL, options: .withoutChanges, error: nil, byAccessor: { readingURL in
			do {
				try self.fileManager.copyItem(at: readingURL, to: localURL)
			} catch CocoaError.fileReadNoSuchFile {
				providerErr = CloudProviderError.itemNotFound
			} catch CocoaError.fileWriteFileExists {
				providerErr = CloudProviderError.itemAlreadyExists
			} catch {
				err = error as NSError
			}
			})
		if let notNilProviderErr = providerErr {
			return Promise(notNilProviderErr)
		} else if let notNilErr = err {
			return Promise(notNilErr)
		}
//		there is no Error
		else {
			return Promise(())
		}
	}

	public func uploadFile(from localURL: URL, to remoteURL: URL, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(remoteURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		precondition(!remoteURL.hasDirectoryPath)
		guard localURL.startAccessingSecurityScopedResource(), remoteURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer {
			localURL.stopAccessingSecurityScopedResource()
			remoteURL.stopAccessingSecurityScopedResource()
		}
		do {
			guard try validateItemType(at: localURL) else {
				return Promise(CloudProviderError.itemTypeMismatch)
			}
		} catch {
			return Promise(error)
		}
		var err: NSError?
		var providerErr: CloudProviderError?
		NSFileCoordinator().coordinate(readingItemAt: remoteURL, options: .withoutChanges, error: nil) { readingURL in
			do {
				if replaceExisting {
					guard try validateItemType(at: remoteURL) else {
						providerErr = CloudProviderError.itemTypeMismatch
						return
					}
					try fileManager.copyItemWithOverwrite(at: readingURL, to: remoteURL)
				} else {
					try fileManager.copyItem(at: readingURL, to: remoteURL)
				}
			} catch CocoaError.fileReadNoSuchFile {
				providerErr = CloudProviderError.itemNotFound
			} catch CocoaError.fileWriteFileExists {
				providerErr = CloudProviderError.itemAlreadyExists
			} catch CocoaError.fileNoSuchFile {
				providerErr = CloudProviderError.parentFolderDoesNotExist
			} catch CocoaError.fileWriteOutOfSpace {
				providerErr = CloudProviderError.quotaInsufficient
			} catch {
				err = error as NSError
			}
		}
		if let notNilProviderErr = providerErr {
			return Promise(notNilProviderErr)
		} else if let notNilErr = err {
			return Promise(notNilErr)
		}
//		there is no Error
		else {
			return fetchItemMetadata(at: remoteURL)
		}
	}

	public func createFolder(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		guard remoteURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer {
			remoteURL.stopAccessingSecurityScopedResource()
		}
		var err: NSError?
		var providerErr: CloudProviderError?
		NSFileCoordinator().coordinate(writingItemAt: remoteURL, options: .forReplacing, error: nil) { writingURL in
			do {
				try fileManager.createDirectory(at: writingURL, withIntermediateDirectories: false, attributes: nil)
			} catch CocoaError.fileWriteFileExists {
				providerErr = CloudProviderError.itemAlreadyExists
			} catch CocoaError.fileNoSuchFile {
				providerErr = CloudProviderError.parentFolderDoesNotExist
			} catch CocoaError.fileWriteOutOfSpace {
				providerErr = CloudProviderError.quotaInsufficient
			} catch {
				err = error as NSError
			}
		}
		if let notNilProviderErr = providerErr {
			return Promise(notNilProviderErr)
		} else if let notNilErr = err {
			return Promise(notNilErr)
		}
//		there is no Error
		else {
			return Promise(())
		}
	}

	public func deleteItem(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		guard remoteURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer {
			remoteURL.stopAccessingSecurityScopedResource()
		}
		do {
			guard try validateItemType(at: remoteURL) else {
				return Promise(CloudProviderError.itemTypeMismatch)
			}
		} catch {
			return Promise(error)
		}
		var err: NSError?
		var providerErr: CloudProviderError?
		NSFileCoordinator().coordinate(writingItemAt: remoteURL, options: .forDeleting, error: nil) { writingURL in
			do {
				try fileManager.removeItem(at: writingURL)
			} catch CocoaError.fileReadNoSuchFile {
				providerErr = CloudProviderError.itemNotFound
			} catch {
				err = error as NSError
			}
		}
		if let notNilProviderErr = providerErr {
			return Promise(notNilProviderErr)
		} else if let notNilErr = err {
			return Promise(notNilErr)
		}
//		there is no Error
		else {
			return Promise(())
		}
	}

	public func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void> {
		precondition(oldRemoteURL.isFileURL)
		precondition(newRemoteURL.isFileURL)
		precondition(oldRemoteURL.hasDirectoryPath == newRemoteURL.hasDirectoryPath)
		guard oldRemoteURL.startAccessingSecurityScopedResource(), newRemoteURL.startAccessingSecurityScopedResource() else {
			return Promise(CloudProviderError.unauthorized)
		}
		defer {
			oldRemoteURL.stopAccessingSecurityScopedResource()
			newRemoteURL.stopAccessingSecurityScopedResource()
		}
		do {
			guard try validateItemType(at: oldRemoteURL) else {
				return Promise(CloudProviderError.itemTypeMismatch)
			}
		} catch {
			return Promise(error)
		}
		var err: NSError?
		var providerErr: CloudProviderError?
		NSFileCoordinator().coordinate(writingItemAt: oldRemoteURL, options: .forMoving, error: nil) { writingURL in
			do {
				try fileManager.moveItem(at: writingURL, to: newRemoteURL)
			} catch CocoaError.fileReadNoSuchFile {
				providerErr = CloudProviderError.itemNotFound
			} catch CocoaError.fileWriteFileExists {
				providerErr = CloudProviderError.itemAlreadyExists
			} catch CocoaError.fileNoSuchFile {
				providerErr = CloudProviderError.parentFolderDoesNotExist
			} catch CocoaError.fileWriteOutOfSpace {
				providerErr = CloudProviderError.quotaInsufficient
			} catch {
				err = error as NSError
			}
		}
		if let notNilProviderErr = providerErr {
			return Promise(notNilProviderErr)
		} else if let notNilErr = err {
			return Promise(notNilErr)
		}
//		there is no Error
		else {
			return Promise(())
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
