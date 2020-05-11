//
//  VaultFormat7ProviderDecorator.swift
//  CloudAccess
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
import CryptomatorCryptoLib

public class VaultFormat7ProviderDecorator: CloudProvider {
	
	let delegate: CloudProvider
	let pathToVault: URL
	let cryptor: Cryptor
	let tmpDir: URL
	
	var dirIds = [URL(fileURLWithPath: "/"): Data(count: 0)]
	
	public init(delegate: CloudProvider, remotePathToVault: URL, cryptor: Cryptor) throws {
		self.delegate = delegate
		self.pathToVault = remotePathToVault
		self.cryptor = cryptor
		self.tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
	}
	
	private func getDirId(cleartextURL: URL) -> Promise<Data> {
		if let dirId = dirIds[cleartextURL] {
			return Promise(dirId)
		} else {
			return getDirId(cleartextURL: cleartextURL.deletingLastPathComponent()).then { parentDirId -> Promise<CloudItemMetadata> in
				let ciphertextName = try self.cryptor.encryptFileName(cleartextURL.lastPathComponent, dirId: parentDirId)
				let dirFilePath = try self.getDirPath(parentDirId).appendingPathComponent(ciphertextName + ".c9r/dir.c9r")
				return self.delegate.fetchItemMetadata(at: dirFilePath)
			}.then { metadata -> Promise<CloudFile> in
				let localDirIdUrl = self.tmpDir.appendingPathComponent(UUID().uuidString)
				let cloudFile = CloudFile(localURL: localDirIdUrl, metadata: metadata)
				return self.delegate.downloadFile(cloudFile)
			}.then { cloudFile -> Data in
				return try Data(contentsOf: cloudFile.localURL)
			}
		}
	}
	
	private func getDirPath(_ dirId: Data) throws -> URL {
		let digest = try self.cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return pathToVault.appendingPathComponent("d/" + digest[..<i] + "/" + digest[i...] + "/")
	}
	
	public func fetchItemMetadata(at cleartextURL: URL) -> Promise<CloudItemMetadata> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func fetchItemList(forFolderAt cleartextURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let dirIdPromise = getDirId(cleartextURL: cleartextURL)
		
		let itemListPromise = dirIdPromise.then { dirId -> Promise<CloudItemList> in
			let dirPath = try self.getDirPath(dirId)
			return self.delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		}
		
		return all(dirIdPromise, itemListPromise).then { (dirId, list) -> CloudItemList in
			let cleartextItems = try list.items.compactMap { metadata -> CloudItemMetadata? in
				guard let extRange = metadata.name.range(of: ".c9r", options: .caseInsensitive) else {
					return nil // not a cryptomator file
				}
				let ciphertextName = String(metadata.name[..<extRange.lowerBound])
				let cleartextName = try self.cryptor.decryptFileName(ciphertextName, dirId: dirId)
				let cleartextSize = NSNumber(value: 0) // TODO determine cleartext size
				return CloudItemMetadata(name: cleartextName, size: cleartextSize, remoteURL: metadata.remoteURL, lastModifiedDate: metadata.lastModifiedDate, itemType: metadata.itemType) // TODO determine itemType
			}
			return CloudItemList(items: cleartextItems, nextPageToken: list.nextPageToken)
		}
	}
	
	public func downloadFile(_ file: CloudFile) -> Promise<CloudFile> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func uploadFile(_ file: CloudFile, isUpdate: Bool) -> Promise<CloudItemMetadata> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func createFolder(at cleartextURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func deleteItem(at cleartextURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func moveItem(from oldCleartextURL: URL, to newCleartextURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	

}
