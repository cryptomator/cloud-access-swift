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
		return getCiphertextURL(cleartextURL).then { ciphertextURL -> Promise<CloudItemMetadata> in
			return self.delegate.fetchItemMetadata(at: ciphertextURL)
		}.then { ciphertextMetadata in
			return self.cleartextMetadata(ciphertextMetadata, cleartextParentUrl: cleartextURL.deletingLastPathComponent())
		}
	}

	public func fetchItemList(forFolderAt cleartextURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		precondition(cleartextURL.hasDirectoryPath)

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
		precondition(!cleartextURL.hasDirectoryPath)
		precondition(!localURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func uploadFile(from localURL: URL, to cleartextURL: URL, isUpdate: Bool, progress: Progress?) -> Promise<CloudItemMetadata> {
		precondition(!localURL.hasDirectoryPath)
		precondition(!cleartextURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func createFolder(at cleartextURL: URL) -> Promise<Void> {
		precondition(cleartextURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func deleteItem(at cleartextURL: URL) -> Promise<Void> {
		if cleartextURL.hasDirectoryPath {
			return getDirId(cleartextURL: cleartextURL).then { dirId throws -> Promise<Void> in
				return self.deleteCiphertextDir(dirId)
			}.then { _ -> Promise<URL> in
				return self.getCiphertextURL(cleartextURL)
			}.then { ciphertextURL in
				return self.delegate.deleteItem(at: ciphertextURL)
			}
		} else {
			return getCiphertextURL(cleartextURL).then { ciphertextURL in
				return self.delegate.deleteItem(at: ciphertextURL)
			}
		}
	}

	public func moveItem(from oldCleartextURL: URL, to newCleartextURL: URL) -> Promise<Void> {
		precondition(oldCleartextURL.hasDirectoryPath == newCleartextURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	// MARK: - Internal

	private func deleteCiphertextDir(_ dirId: Data) -> Promise<Void> {
		let ciphertextDir: URL
		do {
			ciphertextDir = try getDirPath(dirId)
		} catch {
			return Promise(error)
		}
		return delegate.fetchItemListExhaustively(forFolderAt: ciphertextDir).then { ciphertextItemList -> Promise<Void> in
			let subDirs = ciphertextItemList.items.filter { $0.remoteURL.hasDirectoryPath }
			let subDirItemListPromises = subDirs.map { self.delegate.fetchItemListExhaustively(forFolderAt: $0.remoteURL) }
			return all(subDirItemListPromises).then { subDirItemLists -> Promise<[Maybe<Data>]> in
				// find subdirectories
				let allDirFiles = subDirItemLists.flatMap { $0.items }.filter { $0.name == "dir.c9r" }
				let dirIdPromises = allDirFiles.map { self.getRemoteFileContents($0.remoteURL) }
				return any(dirIdPromises)
			}.then { dirIds throws -> Promise<[Maybe<Void>]> in
				// delete subdirectories recursively
				let recursiveDeleteOperations = dirIds.filter { $0.value != nil }.map { self.deleteCiphertextDir($0.value!) }
				return any(recursiveDeleteOperations)
			}.then { _ -> Promise<Void> in
				// delete self
				return self.delegate.deleteItem(at: ciphertextDir)
			}
		}
	}

	private func getCiphertextURL(_ cleartextURL: URL) -> Promise<URL> {
		let cleartextParent = cleartextURL.deletingLastPathComponent()
		let cleartextName = cleartextURL.lastPathComponent
		return getDirId(cleartextURL: cleartextParent).then { dirId -> URL in
			let ciphertextParentPath = try self.getDirPath(dirId)
			let ciphertextName = try self.cryptor.encryptFileName(cleartextName, dirId: dirId)
			return ciphertextParentPath.appendingPathComponent(ciphertextName + ".c9r", isDirectory: cleartextURL.hasDirectoryPath)
		}
	}

	private func getDirId(cleartextURL: URL) -> Promise<Data> {
		return dirIdCache.get(cleartextURL, onMiss: { (url, parentDirId) throws -> Promise<Data> in
			let ciphertextName = try self.cryptor.encryptFileName(url.lastPathComponent, dirId: parentDirId)
			let dirFileURL = try self.getDirPath(parentDirId).appendingPathComponent(ciphertextName + ".c9r/dir.c9r")
			return self.getRemoteFileContents(dirFileURL)
		})
	}

	private func getRemoteFileContents(_ remoteURL: URL) -> Promise<Data> {
		let localURL = tmpDir.appendingPathComponent(UUID().uuidString)
		return delegate.downloadFile(from: remoteURL, to: localURL, progress: nil).then { _ in
			return try Data(contentsOf: localURL)
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
