//
//  CloudProviderMock.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
import CloudAccess


let lastModifiedDate = Date.init(timeIntervalSinceReferenceDate: 0)

let masterkeyContents = """
	{
		"version": 7,
		"scryptSalt": "AAAAAAAAAAA=",
		"scryptCostParam": 2,
		"scryptBlockSize": 8,
		"primaryMasterKey": "mM+qoQ+o0qvPTiDAZYt+flaC3WbpNAx1sTXaUzxwpy0M9Ctj6Tih/Q==",
		"hmacMasterKey": "mM+qoQ+o0qvPTiDAZYt+flaC3WbpNAx1sTXaUzxwpy0M9Ctj6Tih/Q==",
		"versionMac": "cn2sAK6l9p1/w9deJVUuW3h7br056mpv5srvALiYw+g="
	}
	"""

public class CloudProviderMock: CloudProvider {
	
	let dirs = [
		"pathToVault",
		"pathToVault/d",
		"pathToVault/d/AA",
		"pathToVault/d/AA/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
	]
	
	let files = [
		"pathToVault/masterkey.cryptomator": Data(masterkeyContents.utf8)
	]
	
	public func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata> {
		if dirs.filter({ remoteURL.relativePath.hasSuffix($0) }).count > 0 {
			return Promise {
				CloudItemMetadata(name: remoteURL.lastPathComponent, size: 0, remoteURL: remoteURL, lastModifiedDate: lastModifiedDate, itemType: .folder)
			}
		} else if let file = files.filter({ remoteURL.relativePath.hasSuffix($0.key) }).first {
			return Promise {
				CloudItemMetadata(name: remoteURL.lastPathComponent, size: NSNumber(value: file.value.count), remoteURL: remoteURL, lastModifiedDate: lastModifiedDate, itemType: .file)
			}
		} else {
			return Promise(CloudProviderError.itemNotFound)
		}
	}
	
	public func fetchItemList(forFolderAt remoteURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let parentPath = remoteURL.relativePath;
		let parentPathLvl = parentPath.components(separatedBy: "/").count - (parentPath.hasSuffix("/") ? 1 : 0)
		let childDirs = dirs.filter({ $0.hasPrefix(parentPath) && $0.components(separatedBy: "/").count == parentPathLvl + 1 })
		let childFiles = files.keys.filter({ $0.hasPrefix(parentPath) && $0.components(separatedBy: "/").count == parentPathLvl + 1 })
		let children = childDirs + childFiles
		return Promise { fulfill, reject in
			let metadataPromises = children.map({ self.fetchItemMetadata(at: remoteURL.appendingPathComponent($0)) })
			all(metadataPromises).then { metadata in
				fulfill(CloudItemList(items: metadata))
			}.catch { error in
				reject(error)
			}
		}
	}
	
	
	public func createBackgroundDownloadTask(for file: CloudFile, with delegate: URLSessionTaskDelegate) -> Promise<URLSessionDownloadTask> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func createBackgroundUploadTask(for file: CloudFile, isUpdate: Bool, with delegate: URLSessionTaskDelegate) -> Promise<URLSessionUploadTask> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func createFolder(at remoteURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func deleteItem(at remoteURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	

}
