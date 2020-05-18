//
//  VaultFormat7ProviderDecorator.swift
//  CloudAccess
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import Promises

enum VaultFormat7Error: Error {
	case encounteredUnrelatedFile
}

public class VaultFormat7ProviderDecorator: CloudProvider {
	let delegate: CloudProvider
	let pathToVault: URL
	let cryptor: Cryptor
	let tmpDir: URL
	let dirIdCache: DirectoryIdCache

	public init(delegate: CloudProvider, remotePathToVault: URL, cryptor: Cryptor) throws {
		self.delegate = delegate
		self.pathToVault = remotePathToVault
		self.cryptor = cryptor
		self.tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
		self.dirIdCache = try DirectoryIdCache()
		try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cleartextURL: URL) -> Promise<CloudItemMetadata> {
		let cleartextParent = cleartextURL.deletingLastPathComponent()
		let cleartextName = cleartextURL.lastPathComponent

		return getDirId(cleartextURL: cleartextParent).then { dirId -> Promise<CloudItemMetadata> in
			let ciphertextParentPath = try self.getDirPath(dirId)
			let ciphertextName = try self.cryptor.encryptFileName(cleartextName, dirId: dirId)
			let ciphertextPath = ciphertextParentPath.appendingPathComponent(ciphertextName + ".c9r")
			return self.delegate.fetchItemMetadata(at: ciphertextPath)
		}.then { ciphertextMetadata in
			self.cleartextMetadata(ciphertextMetadata, cleartextParentUrl: cleartextParent)
		}
	}

	public func fetchItemList(forFolderAt cleartextURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let dirIdPromise = getDirId(cleartextURL: cleartextURL)

		let itemListPromise = dirIdPromise.then { dirId -> Promise<CloudItemList> in
			let dirPath = try self.getDirPath(dirId)
			return self.delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		}

		return all(dirIdPromise, itemListPromise).then { (_, list) -> Promise<CloudItemList> in
			let cleartextItemPromises = list.items.map { self.cleartextMetadata($0, cleartextParentUrl: cleartextURL) }
			return any(cleartextItemPromises).then { maybeCleartextItems -> CloudItemList in
				let cleartextItems = maybeCleartextItems.filter { $0.value != nil }.map { $0.value! }
				return CloudItemList(items: cleartextItems, nextPageToken: list.nextPageToken)
			}
		}
	}

	public func downloadFile(from cleartextURL: URL, to localURL: URL, progress: Progress?) -> Promise<CloudItemMetadata> {
		Promise(CloudProviderError.noInternetConnection)
	}

	public func uploadFile(from localURL: URL, to cleartextURL: URL, isUpdate: Bool, progress: Progress?) -> Promise<CloudItemMetadata> {
		Promise(CloudProviderError.noInternetConnection)
	}

	public func createFolder(at cleartextURL: URL) -> Promise<Void> {
		Promise(CloudProviderError.noInternetConnection)
	}

	public func deleteItem(at cleartextURL: URL) -> Promise<Void> {
		Promise(CloudProviderError.noInternetConnection)
	}

	public func moveItem(from oldCleartextURL: URL, to newCleartextURL: URL) -> Promise<Void> {
		Promise(CloudProviderError.noInternetConnection)
	}

	// MARK: - Internal

	private func getDirId(cleartextURL: URL) -> Promise<Data> {
		return dirIdCache.get(cleartextURL) { (url, parentDirId) throws -> Promise<Data> in
			let ciphertextName = try self.cryptor.encryptFileName(url.lastPathComponent, dirId: parentDirId)
			let remoteDirFilePath = try self.getDirPath(parentDirId).appendingPathComponent(ciphertextName + ".c9r/dir.c9r")
			let localDirFilePath = self.tmpDir.appendingPathComponent(UUID().uuidString)
			return self.delegate.downloadFile(from: remoteDirFilePath, to: localDirFilePath, progress: nil).then { _ in
				try Data(contentsOf: localDirFilePath)
			}
		}
	}

	private func getDirPath(_ dirId: Data) throws -> URL {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return pathToVault.appendingPathComponent("d/" + digest[..<i] + "/" + digest[i...] + "/", isDirectory: true)
	}

	private func cleartextMetadata(_ metadata: CloudItemMetadata, cleartextParentUrl: URL) -> Promise<CloudItemMetadata> {
		getDirId(cleartextURL: cleartextParentUrl).then { parentDirId -> CloudItemMetadata in
			// TODO: unshorten .c9s names
			guard let extRange = metadata.name.range(of: ".c9r", options: .caseInsensitive) else {
				throw VaultFormat7Error.encounteredUnrelatedFile // not a Cryptomator file
			}
			let ciphertextName = String(metadata.name[..<extRange.lowerBound])
			let cleartextName = try self.cryptor.decryptFileName(ciphertextName, dirId: parentDirId)
			let cleartextURL = cleartextParentUrl.appendingPathComponent(cleartextName)
			let cleartextSize = 0 // TODO: determine cleartext size
			return CloudItemMetadata(name: cleartextName, remoteURL: cleartextURL, itemType: metadata.itemType, lastModifiedDate: metadata.lastModifiedDate, size: cleartextSize) // TODO: determine itemType
		}
	}
}
