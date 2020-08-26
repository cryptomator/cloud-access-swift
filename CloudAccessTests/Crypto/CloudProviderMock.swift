//
//  CloudProviderMock.swift
//  CloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
@testable import CloudAccess

public class CloudProviderMock: CloudProvider {
	let folders: Set<String>
	let files: [String: Data]
	let lastModifiedDate = Date(timeIntervalSinceReferenceDate: 0)

	var createdFolders: [String] = []
	var createdFiles: [String: Data] = [:]
	var deleted: [String] = []
	var moved: [String: String] = [:]

	init(folders: Set<String>, files: [String: Data]) {
		self.folders = folders
		self.files = files
	}

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		if folders.contains(cloudPath.path) {
			return Promise(CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .folder, lastModifiedDate: lastModifiedDate, size: 0))
		} else if let data = files[cloudPath.path] {
			return Promise(CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .file, lastModifiedDate: lastModifiedDate, size: data.count))
		} else {
			return Promise(CloudProviderError.itemNotFound)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken _: String?) -> Promise<CloudItemList> {
		precondition(cloudPath.hasDirectoryPath)
		let parentPath = cloudPath.path
		let parentPathLvl = parentPath.components(separatedBy: "/").count
		let childDirs = folders.filter { $0.hasPrefix(parentPath) && $0.components(separatedBy: "/").count == parentPathLvl + 1 }
		let childFiles = files.keys.filter { $0.hasPrefix(parentPath) && $0.components(separatedBy: "/").count == parentPathLvl }
		let children = childDirs + childFiles
		let metadataPromises = children.map { self.fetchItemMetadata(at: CloudPath($0)) }
		return all(metadataPromises).then { metadata in
			return CloudItemList(items: metadata)
		}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		precondition(!cloudPath.hasDirectoryPath)
		precondition(!localURL.hasDirectoryPath)
		if let data = files[cloudPath.path] {
			do {
				try data.write(to: localURL, options: .withoutOverwriting)
			} catch {
				return Promise(error)
			}
			return Promise(())
		} else {
			return Promise(CloudProviderError.itemNotFound)
		}
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		precondition(!cloudPath.hasDirectoryPath)
		do {
			let data = try Data(contentsOf: localURL)
			createdFiles[cloudPath.path] = data
			return Promise(CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .file, lastModifiedDate: lastModifiedDate, size: data.count))
		} catch {
			return Promise(error)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		precondition(cloudPath.hasDirectoryPath)
		createdFolders.append(cloudPath.path)
		return Promise(())
	}

	public func deleteItem(at cloudPath: CloudPath) -> Promise<Void> {
		deleted.append(cloudPath.path)
		return Promise(())
	}

	public func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		precondition(sourceCloudPath.hasDirectoryPath == targetCloudPath.hasDirectoryPath)
		moved[sourceCloudPath.path] = targetCloudPath.path
		return Promise(())
	}
}
