//
//  CloudProviderMock.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
@testable import CloudAccess

/**
 ```
 pathToVault
 ├─ Directory 1
 │  ├─ Directory 2
 │  └─ File 3
 ├─ Directory 3 (Long)
 │  ├─ Directory 4 (Long)
 │  └─ File 6 (Long)
 ├─ File 1
 ├─ File 2
 ├─ File 4 (Long)
 └─ File 5 (Long)
 ```
 */
public class CloudProviderMock: CloudProvider {
	let folders: Set = [
		"pathToVault/",
		"pathToVault/d/",
		"pathToVault/d/00/",
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/",
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/",
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/", // (dir3){55}.c9r
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/", // (file4){44}.c9r
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/", // (file5){44}.c9r
		"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/",
		"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r/",
		"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/",
		"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/",
		"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/ImoW6Jb8d-kdR00uEadGd1_TJDM=.c9s/", // (dir4){55}.c9r
		"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s/", // (file6){44}.c9r
		"pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE/"
	]
	let files = [
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r": "dir1-id".data(using: .utf8)!,
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/dir.c9r": "dir3-id".data(using: .utf8)!,
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s": "\(String(repeating: "dir3", count: 55)).c9r".data(using: .utf8)!,
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r": "ciphertext1".data(using: .utf8)!,
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file2.c9r": "ciphertext2".data(using: .utf8)!,
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r": "ciphertext4".data(using: .utf8)!,
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s": "\(String(repeating: "file4", count: 44)).c9r".data(using: .utf8)!,
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/contents.c9r": "ciphertext5".data(using: .utf8)!,
		"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/name.c9s": "\(String(repeating: "file5", count: 44)).c9r".data(using: .utf8)!,
		"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r/dir.c9r": "dir2-id".data(using: .utf8)!,
		"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r": "ciphertext3".data(using: .utf8)!,
		"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/ImoW6Jb8d-kdR00uEadGd1_TJDM=.c9s/dir.c9r": "dir4-id".data(using: .utf8)!,
		"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/ImoW6Jb8d-kdR00uEadGd1_TJDM=.c9s/name.c9s": "\(String(repeating: "dir4", count: 55)).c9r".data(using: .utf8)!,
		"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s/contents.c9r": "ciphertext6".data(using: .utf8)!,
		"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s/name.c9s": "\(String(repeating: "file6", count: 44)).c9r".data(using: .utf8)!
	]
	let lastModifiedDate = Date(timeIntervalSinceReferenceDate: 0)

	var createdFolders: [String] = []
	var createdFiles: [String: Data] = [:]
	var deleted: [String] = []
	var moved: [String: String] = [:]

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
