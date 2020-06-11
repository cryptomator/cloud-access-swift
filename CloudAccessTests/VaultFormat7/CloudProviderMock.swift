//
//  CloudProviderMock.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CloudAccess
import Foundation
import Promises

let lastModifiedDate = Date(timeIntervalSinceReferenceDate: 0)

public class CloudProviderMock: CloudProvider {
	let dirs: Set = [
		"pathToVault",
		"pathToVault/d",
		"pathToVault/d/00",
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r",
		"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
		"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r",
		"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
	]

	let files = [
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r": Data(count: 0),
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file2.c9r": Data(count: 0),
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r": "dir1-id".data(using: .utf8)!,
		"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r": Data(count: 0),
		"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r/dir.c9r": "dir2-id".data(using: .utf8)!
	]

	var deleted: [String] = []
	var moved: [String: String] = [:]

	public func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata> {
		if dirs.contains(remoteURL.relativePath) {
			return Promise {
				CloudItemMetadata(name: remoteURL.lastPathComponent, remoteURL: remoteURL, itemType: .folder, lastModifiedDate: lastModifiedDate, size: 0)
			}
		} else if let data = files[remoteURL.relativePath] {
			return Promise {
				CloudItemMetadata(name: remoteURL.lastPathComponent, remoteURL: remoteURL, itemType: .file, lastModifiedDate: lastModifiedDate, size: data.count)
			}
		} else {
			return Promise(CloudProviderError.itemNotFound)
		}
	}

	public func fetchItemList(forFolderAt remoteURL: URL, withPageToken _: String?) -> Promise<CloudItemList> {
		precondition(remoteURL.hasDirectoryPath)
		let parentPath = remoteURL.relativePath
		let parentPathLvl = parentPath.components(separatedBy: "/").count - (parentPath.hasSuffix("/") ? 1 : 0)
		let childDirs = dirs.filter { $0.hasPrefix(parentPath) && $0.components(separatedBy: "/").count == parentPathLvl + 1 }
		let childFiles = files.keys.filter { $0.hasPrefix(parentPath) && $0.components(separatedBy: "/").count == parentPathLvl + 1 }
		let children = childDirs + childFiles
		return Promise { fulfill, reject in
			let metadataPromises = children.map { self.fetchItemMetadata(at: URL(fileURLWithPath: $0, isDirectory: childDirs.contains($0))) }
			all(metadataPromises).then { metadata in
				fulfill(CloudItemList(items: metadata))
			}.catch { error in
				reject(error)
			}
		}
	}

	public func downloadFile(from remoteURL: URL, to localURL: URL, progress: Progress?) -> Promise<Void> {
		precondition(!remoteURL.hasDirectoryPath)
		precondition(!localURL.hasDirectoryPath)
		if let data = files[remoteURL.relativePath] {
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

	public func uploadFile(from localURL: URL, to remoteURL: URL, isUpdate: Bool, progress: Progress?) -> Promise<CloudItemMetadata> {
		precondition(!localURL.hasDirectoryPath)
		precondition(!remoteURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func createFolder(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func deleteItem(at remoteURL: URL) -> Promise<Void> {
		deleted.append(remoteURL.relativePath)
		return Promise(())
	}

	public func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void> {
		precondition(oldRemoteURL.hasDirectoryPath == newRemoteURL.hasDirectoryPath)
		moved[oldRemoteURL.relativePath] = newRemoteURL.relativePath
		return Promise(())
	}
}
