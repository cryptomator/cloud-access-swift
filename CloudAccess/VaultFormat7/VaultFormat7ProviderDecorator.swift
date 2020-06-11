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
	let vaultURL: URL
	let cryptor: Cryptor
	let tmpDirURL: URL
	let dirIdCache: DirectoryIdCache

	public init(delegate: CloudProvider, remoteVaultURL: URL, cryptor: Cryptor) throws {
		self.delegate = delegate
		self.vaultURL = remoteVaultURL
		self.cryptor = cryptor
		self.tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		self.dirIdCache = try DirectoryIdCache()
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cleartextURL: URL) -> Promise<CloudItemMetadata> {
		precondition(cleartextURL.isFileURL)
		return getCiphertextURL(cleartextURL).then { ciphertextURL in
			return self.delegate.fetchItemMetadata(at: ciphertextURL)
		}.then { ciphertextMetadata in
			return self.cleartextMetadata(ciphertextMetadata, cleartextParentURL: cleartextURL.deletingLastPathComponent())
		}
	}

	public func fetchItemList(forFolderAt cleartextURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		precondition(cleartextURL.isFileURL)
		precondition(cleartextURL.hasDirectoryPath)
		return getDirId(cleartextURL: cleartextURL).then { dirId -> Promise<CloudItemList> in
			let dirPath = try self.getDirPath(dirId)
			return self.delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		}.then { list -> Promise<CloudItemList> in
			let cleartextItemPromises = list.items.map { self.cleartextMetadata($0, cleartextParentURL: cleartextURL) }
			return any(cleartextItemPromises).then { maybeCleartextItems in
				let cleartextItems = maybeCleartextItems.filter { $0.value != nil }.map { $0.value! }
				return Promise(CloudItemList(items: cleartextItems, nextPageToken: list.nextPageToken))
			}
		}
	}

	public func downloadFile(from remoteCleartextURL: URL, to localCleartextURL: URL, progress: Progress?) -> Promise<Void> {
		precondition(remoteCleartextURL.isFileURL)
		precondition(localCleartextURL.isFileURL)
		precondition(!remoteCleartextURL.hasDirectoryPath)
		precondition(!localCleartextURL.hasDirectoryPath)
		let localCiphertextURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		return getCiphertextURL(remoteCleartextURL).then { remoteCiphertextURL in
			return self.delegate.downloadFile(from: remoteCiphertextURL, to: localCiphertextURL, progress: progress)
		}.then {
			try self.cryptor.decryptContent(from: localCiphertextURL, to: localCleartextURL)
		}
	}

	public func uploadFile(from localURL: URL, to cleartextURL: URL, isUpdate: Bool, progress: Progress?) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(cleartextURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		precondition(!cleartextURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func createFolder(at cleartextURL: URL) -> Promise<Void> {
		precondition(cleartextURL.isFileURL)
		precondition(cleartextURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func deleteItem(at cleartextURL: URL) -> Promise<Void> {
		precondition(cleartextURL.isFileURL)
		if cleartextURL.hasDirectoryPath {
			return getDirId(cleartextURL: cleartextURL).then { dirId in
				return self.deleteCiphertextDir(dirId)
			}.then {
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
		precondition(oldCleartextURL.isFileURL)
		precondition(newCleartextURL.isFileURL)
		precondition(oldCleartextURL.hasDirectoryPath == newCleartextURL.hasDirectoryPath)
		return all(
			getCiphertextURL(oldCleartextURL),
			getCiphertextURL(newCleartextURL)
		).then { oldCiphertextURL, newCiphertextURL in
			return self.delegate.moveItem(from: oldCiphertextURL, to: newCiphertextURL)
		}
	}

	// MARK: - Internal

	private func deleteCiphertextDir(_ dirId: Data) -> Promise<Void> {
		let ciphertextDir: URL
		do {
			ciphertextDir = try getDirPath(dirId)
		} catch {
			return Promise(error)
		}
		return delegate.fetchItemListExhaustively(forFolderAt: ciphertextDir).then { ciphertextItemList in
			let subDirs = ciphertextItemList.items.filter { $0.remoteURL.hasDirectoryPath }
			let subDirItemListPromises = subDirs.map { self.delegate.fetchItemListExhaustively(forFolderAt: $0.remoteURL) }
			return all(subDirItemListPromises).then { subDirItemLists -> Promise<[Maybe<Data>]> in
				// find subdirectories
				let allDirFiles = subDirItemLists.flatMap { $0.items }.filter { $0.name == "dir.c9r" }
				let dirIdPromises = allDirFiles.map { self.getRemoteFileContents($0.remoteURL) }
				return any(dirIdPromises)
			}.then { dirIds -> Promise<[Maybe<Void>]> in
				// delete subdirectories recursively
				let recursiveDeleteOperations = dirIds.filter { $0.value != nil }.map { self.deleteCiphertextDir($0.value!) }
				return any(recursiveDeleteOperations)
			}.then { _ in
				// delete self
				return self.delegate.deleteItem(at: ciphertextDir)
			}
		}
	}

	private func getCiphertextURL(_ cleartextURL: URL) -> Promise<URL> {
		let cleartextParent = cleartextURL.deletingLastPathComponent()
		let cleartextName = cleartextURL.lastPathComponent
		return getDirId(cleartextURL: cleartextParent).then { dirId in
			let ciphertextParentPath = try self.getDirPath(dirId)
			let ciphertextName = try self.cryptor.encryptFileName(cleartextName, dirId: dirId)
			return Promise(ciphertextParentPath.appendingPathComponent(ciphertextName + ".c9r", isDirectory: cleartextURL.hasDirectoryPath))
		}
	}

	private func getDirId(cleartextURL: URL) -> Promise<Data> {
		return dirIdCache.get(cleartextURL, onMiss: { url, parentDirId in
			let ciphertextName = try self.cryptor.encryptFileName(url.lastPathComponent, dirId: parentDirId)
			let dirFileURL = try self.getDirPath(parentDirId).appendingPathComponent(ciphertextName + ".c9r/dir.c9r")
			return self.getRemoteFileContents(dirFileURL)
		})
	}

	private func getRemoteFileContents(_ remoteURL: URL) -> Promise<Data> {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		return delegate.downloadFile(from: remoteURL, to: localURL, progress: nil).then {
			return try Data(contentsOf: localURL)
		}
	}

	private func getDirPath(_ dirId: Data) throws -> URL {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultURL.appendingPathComponent("d/" + digest[..<i] + "/" + digest[i...] + "/", isDirectory: true)
	}

	private func cleartextMetadata(_ metadata: CloudItemMetadata, cleartextParentURL: URL) -> Promise<CloudItemMetadata> {
		getDirId(cleartextURL: cleartextParentURL).then { parentDirId in
			// TODO: unshorten .c9s names
			guard let extRange = metadata.name.range(of: ".c9r", options: .caseInsensitive) else {
				throw VaultFormat7Error.encounteredUnrelatedFile // not a Cryptomator file
			}
			let ciphertextName = String(metadata.name[..<extRange.lowerBound])
			let cleartextName = try self.cryptor.decryptFileName(ciphertextName, dirId: parentDirId)
			let cleartextURL = cleartextParentURL.appendingPathComponent(cleartextName)
			let cleartextSize = 0 // TODO: determine cleartext size
			return Promise(CloudItemMetadata(name: cleartextName, remoteURL: cleartextURL, itemType: metadata.itemType, lastModifiedDate: metadata.lastModifiedDate, size: cleartextSize)) // TODO: determine itemType
		}
	}
}
