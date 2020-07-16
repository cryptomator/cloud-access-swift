//
//  LocalFileSystemProvider.swift
//  CloudAccess
//
//  Created by Wahid Ali on 27.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

extension FileManager {
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

	public init() {}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata> {
		precondition(remoteURL.isFileURL)
		let attributes: [FileAttributeKey: Any]
		do {
			attributes = try fileManager.attributesOfItem(atPath: remoteURL.path)
		} catch CocoaError.fileReadNoSuchFile {
			return Promise(CloudProviderError.itemNotFound)
		} catch {
			return Promise(error)
		}
		let name = remoteURL.lastPathComponent
		let size = attributes[FileAttributeKey.size] as? Int
		let lastModifiedDate = attributes[FileAttributeKey.modificationDate] as? Date
		let itemType = getItemType(from: attributes[FileAttributeKey.type] as? FileAttributeType)
		guard validateItemType(at: remoteURL, with: itemType) else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		return Promise(CloudItemMetadata(name: name, remoteURL: remoteURL, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size))
	}

	public func fetchItemList(forFolderAt remoteURL: URL, withPageToken _: String?) -> Promise<CloudItemList> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		let contents: [URL]
		do {
			contents = try fileManager.contentsOfDirectory(at: remoteURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceTypeKey], options: .skipsHiddenFiles)
		} catch CocoaError.fileReadNoSuchFile {
			return Promise(CloudProviderError.itemNotFound)
		} catch CocoaError.fileReadUnknown {
			return Promise(CloudProviderError.itemTypeMismatch)
		} catch {
			return Promise(error)
		}
		let metadatas = contents.map { url -> CloudItemMetadata in
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
		do {
			guard try validateItemType(at: remoteURL) else {
				return Promise(CloudProviderError.itemTypeMismatch)
			}
			try fileManager.copyItem(at: remoteURL, to: localURL)
			return Promise(())
		} catch CocoaError.fileReadNoSuchFile {
			return Promise(CloudProviderError.itemNotFound)
		} catch CocoaError.fileWriteFileExists {
			return Promise(CloudProviderError.itemAlreadyExists)
		} catch {
			return Promise(error)
		}
	}

	public func uploadFile(from localURL: URL, to remoteURL: URL, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(remoteURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		precondition(!remoteURL.hasDirectoryPath)
		do {
			guard try validateItemType(at: localURL) else {
				return Promise(CloudProviderError.itemTypeMismatch)
			}
			if replaceExisting {
				guard try validateItemType(at: remoteURL) else {
					return Promise(CloudProviderError.itemTypeMismatch)
				}
				try fileManager.copyItemWithOverwrite(at: localURL, to: remoteURL)
			} else {
				try fileManager.copyItem(at: localURL, to: remoteURL)
			}
			return fetchItemMetadata(at: remoteURL)
		} catch CocoaError.fileReadNoSuchFile {
			return Promise(CloudProviderError.itemNotFound)
		} catch CocoaError.fileWriteFileExists {
			return Promise(CloudProviderError.itemAlreadyExists)
		} catch CocoaError.fileNoSuchFile {
			return Promise(CloudProviderError.parentFolderDoesNotExist)
		} catch CocoaError.fileWriteOutOfSpace {
			return Promise(CloudProviderError.quotaInsufficient)
		} catch {
			return Promise(error)
		}
	}

	public func createFolder(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		do {
			try fileManager.createDirectory(at: remoteURL, withIntermediateDirectories: false, attributes: nil)
			return Promise(())
		} catch CocoaError.fileWriteFileExists {
			return Promise(CloudProviderError.itemAlreadyExists)
		} catch CocoaError.fileNoSuchFile {
			return Promise(CloudProviderError.parentFolderDoesNotExist)
		} catch CocoaError.fileWriteOutOfSpace {
			return Promise(CloudProviderError.quotaInsufficient)
		} catch {
			return Promise(error)
		}
	}

	public func deleteItem(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		do {
			guard try validateItemType(at: remoteURL) else {
				return Promise(CloudProviderError.itemTypeMismatch)
			}
			try fileManager.removeItem(at: remoteURL)
			return Promise(())
		} catch CocoaError.fileReadNoSuchFile {
			return Promise(CloudProviderError.itemNotFound)
		} catch {
			return Promise(error)
		}
	}

	public func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void> {
		precondition(oldRemoteURL.isFileURL)
		precondition(newRemoteURL.isFileURL)
		precondition(oldRemoteURL.hasDirectoryPath == newRemoteURL.hasDirectoryPath)
		do {
			guard try validateItemType(at: oldRemoteURL) else {
				return Promise(CloudProviderError.itemTypeMismatch)
			}
			try fileManager.moveItem(at: oldRemoteURL, to: newRemoteURL)
			return Promise(())
		} catch CocoaError.fileReadNoSuchFile {
			return Promise(CloudProviderError.itemNotFound)
		} catch CocoaError.fileWriteFileExists {
			return Promise(CloudProviderError.itemAlreadyExists)
		} catch CocoaError.fileNoSuchFile {
			return Promise(CloudProviderError.parentFolderDoesNotExist)
		} catch CocoaError.fileWriteOutOfSpace {
			return Promise(CloudProviderError.quotaInsufficient)
		} catch {
			return Promise(error)
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
