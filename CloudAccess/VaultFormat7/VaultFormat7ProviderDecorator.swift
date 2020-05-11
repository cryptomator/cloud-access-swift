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

public enum VaultFormat7Error: Error {
	case decryptionError
	case unresolvableDirId(_ reason: String)
}

public class VaultFormat7ProviderDecorator: CloudProvider {
	
	let delegate: CloudProvider
	let pathToVault: URL
	let cryptor: Cryptor
	let tmpDir: URL
	
	var dirIds = Dictionary<URL, String>()
	
	public init(delegate: CloudProvider, remotePathToVault: URL, cryptor: Cryptor) throws {
		self.delegate = delegate
		self.pathToVault = remotePathToVault
		self.cryptor = cryptor
		self.tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
		dirIds[URL(fileURLWithPath: "/")] = cryptor.encryptDirId("")
	}
	
	private func getDirId(cleartextURL: URL) -> Promise<String> {
		if let dirId = dirIds[cleartextURL] {
			return Promise(dirId)
		} else {
			return getDirId(cleartextURL: cleartextURL.deletingLastPathComponent()).then { parentDirId -> Promise<CloudItemMetadata> in
				if let ciphertextName = self.cryptor.encryptFileName(cleartextURL.lastPathComponent, dirId: parentDirId.data(using: .utf8)!) {
					let i = parentDirId.index(parentDirId.startIndex, offsetBy: 2)
					let dirFilePath = "d/" + parentDirId[..<i] + "/" + parentDirId[i...] + "/" + ciphertextName + ".c9r/dir.c9r"
					return self.delegate.fetchItemMetadata(at: self.pathToVault.appendingPathComponent(dirFilePath))
				} else {
					throw VaultFormat7Error.unresolvableDirId("Failed to encrypt cleartext name \(cleartextURL.lastPathComponent)")
				}
			}.then { metadata -> Promise<CloudFile> in
				let localDirIdUrl = self.tmpDir.appendingPathComponent(UUID().uuidString)
				let cloudFile = CloudFile(localURL: localDirIdUrl, metadata: metadata)
				return self.delegate.downloadFile(cloudFile)
			}.then { cloudFile -> String in
				let dirIdData = try Data(contentsOf: cloudFile.localURL)
				if let result = self.cryptor.encryptDirId(String(data: dirIdData, encoding: .utf8)!) {
					return result
				} else {
					throw VaultFormat7Error.unresolvableDirId("dir.c9r file not containing utf8 data")
				}
			}
		}
	}
	
	public func fetchItemMetadata(at cleartextURL: URL) -> Promise<CloudItemMetadata> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func fetchItemList(forFolderAt cleartextURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let dirIdPromise = getDirId(cleartextURL: cleartextURL)
		
		let itemListPromise = dirIdPromise.then { dirId -> Promise<CloudItemList> in
			let i = dirId.index(dirId.startIndex, offsetBy: 2)
			let dirPath = "d/" + dirId[..<i] + "/" + dirId[i...] + "/"
			let ciphertextPath = self.pathToVault.appendingPathComponent(dirPath)
			return self.delegate.fetchItemList(forFolderAt: ciphertextPath, withPageToken: pageToken)
		}
		
		return all(dirIdPromise, itemListPromise).then { (dirId, list) -> CloudItemList in
			let cleartextItems = try list.items.compactMap { metadata -> CloudItemMetadata? in
				guard let extRange = metadata.name.range(of: ".c9r", options: .caseInsensitive) else {
					return nil // not a cryptomator file
				}
				let ciphertextName = String(metadata.name[..<extRange.lowerBound])
				guard let cleartextName = self.cryptor.decryptFileName(ciphertextName, dirId: dirId.data(using: .utf8)!) else {
					throw VaultFormat7Error.decryptionError
				}
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
