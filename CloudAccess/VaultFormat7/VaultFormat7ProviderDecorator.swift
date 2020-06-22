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

private extension URL {
	func appendingDirFileComponent() -> URL {
		return appendingPathComponent("dir.c9r", isDirectory: false)
	}
}

public class VaultFormat7ProviderDecorator: CloudProvider {
	let delegate: CloudProvider
	let vaultURL: URL
	let cryptor: Cryptor
	let dirIdCache: DirectoryIdCache
	let tmpDirURL: URL

	public init(delegate: CloudProvider, vaultURL: URL, cryptor: Cryptor) throws {
		self.delegate = delegate
		self.vaultURL = vaultURL
		self.cryptor = cryptor
		self.dirIdCache = try DirectoryIdCache()
		self.tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cleartextURL: URL) -> Promise<CloudItemMetadata> {
		precondition(cleartextURL.isFileURL)
		return getCiphertextURL(cleartextURL).then { ciphertextURL in
			return self.delegate.fetchItemMetadata(at: ciphertextURL)
		}.then { ciphertextMetadata in
			return self.getCleartextMetadata(ciphertextMetadata, cleartextParentURL: cleartextURL.deletingLastPathComponent())
		}
	}

	public func fetchItemList(forFolderAt cleartextURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		precondition(cleartextURL.isFileURL)
		precondition(cleartextURL.hasDirectoryPath)
		return getDirURL(cleartextURL).then { dirURL in
			return self.delegate.fetchItemList(forFolderAt: dirURL, withPageToken: pageToken)
		}.then { itemList -> Promise<CloudItemList> in
			let cleartextItemPromises = itemList.items.map { self.getCleartextMetadata($0, cleartextParentURL: cleartextURL) }
			return any(cleartextItemPromises).then { maybeCleartextItems -> CloudItemList in
				let cleartextItems = maybeCleartextItems.filter { $0.value != nil }.map { $0.value! }
				return CloudItemList(items: cleartextItems, nextPageToken: itemList.nextPageToken)
			}
		}
	}

	public func downloadFile(from remoteCleartextURL: URL, to localCleartextURL: URL, progress: Progress?) -> Promise<Void> {
		precondition(remoteCleartextURL.isFileURL)
		precondition(localCleartextURL.isFileURL)
		precondition(!remoteCleartextURL.hasDirectoryPath)
		precondition(!localCleartextURL.hasDirectoryPath)
		let localCiphertextURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return getCiphertextURL(remoteCleartextURL).then { remoteCiphertextURL in
			return self.delegate.downloadFile(from: remoteCiphertextURL, to: localCiphertextURL, progress: progress)
		}.then {
			try self.cryptor.decryptContent(from: localCiphertextURL, to: localCleartextURL)
			try? FileManager.default.removeItem(at: localCiphertextURL)
		}
	}

	public func uploadFile(from localCleartextURL: URL, to remoteCleartextURL: URL, replaceExisting: Bool, progress: Progress?) -> Promise<CloudItemMetadata> {
		precondition(localCleartextURL.isFileURL)
		precondition(remoteCleartextURL.isFileURL)
		precondition(!localCleartextURL.hasDirectoryPath)
		precondition(!remoteCleartextURL.hasDirectoryPath)
		let localCiphertextURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return getCiphertextURL(remoteCleartextURL).then { remoteCiphertextURL in
			try self.cryptor.encryptContent(from: localCleartextURL, to: localCiphertextURL)
			return self.delegate.uploadFile(from: localCiphertextURL, to: remoteCiphertextURL, replaceExisting: replaceExisting, progress: progress)
		}.then { ciphertextMetadata in
			return self.getCleartextMetadata(ciphertextMetadata, cleartextParentURL: remoteCleartextURL.deletingLastPathComponent())
		}.always {
			try? FileManager.default.removeItem(at: localCiphertextURL)
		}
	}

	public func createFolder(at cleartextURL: URL) -> Promise<Void> {
		precondition(cleartextURL.isFileURL)
		precondition(cleartextURL.hasDirectoryPath)
		let dirId = UUID().uuidString.data(using: .utf8)!
		let localDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let dirURL: URL
		do {
			try dirId.write(to: localDirFileURL)
			dirURL = try getDirURL(dirId)
		} catch {
			return Promise(error)
		}
		let ciphertextURLPromise = getCiphertextURL(cleartextURL)
		return ciphertextURLPromise.then { ciphertextURL in
			return self.delegate.createFolder(at: ciphertextURL)
		}.then { ciphertextURLPromise }.then { ciphertextURL -> Promise<CloudItemMetadata> in
			let remoteDirFileURL = ciphertextURL.appendingDirFileComponent()
			return self.delegate.uploadFile(from: localDirFileURL, to: remoteDirFileURL, replaceExisting: false, progress: nil)
		}.then { _ -> Promise<Void> in
			let parentDirURL = dirURL.deletingLastPathComponent()
			return self.delegate.createFolder(at: parentDirURL)
		}.recover { error -> Promise<Void> in
			if case CloudProviderError.itemAlreadyExists = error {
				return Promise(())
			} else {
				return Promise(error)
			}
		}.then { () -> Promise<Void> in
			return self.delegate.createFolder(at: dirURL)
		}.always {
			try? FileManager.default.removeItem(at: localDirFileURL)
		}
	}

	public func deleteItem(at cleartextURL: URL) -> Promise<Void> {
		precondition(cleartextURL.isFileURL)
		if cleartextURL.hasDirectoryPath {
			// TODO: recover from error if `getDirId()` rejects with `CloudProviderError.itemNotFound` and delete item anyway (because it's probably a symlink)
			return getDirId(cleartextURL).then { dirId in
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
		return all(getCiphertextURL(oldCleartextURL), getCiphertextURL(newCleartextURL)).then { oldCiphertextURL, newCiphertextURL in
			return self.delegate.moveItem(from: oldCiphertextURL, to: newCiphertextURL)
		}
	}

	// MARK: - Encryption

	private func getDirId(_ cleartextURL: URL) -> Promise<Data> {
		return dirIdCache.get(cleartextURL, onMiss: { url, parentDirId in
			let ciphertextURL = try self.getCiphertextURL(url, parentDirId: parentDirId)
			let dirFileURL = ciphertextURL.appendingDirFileComponent()
			return self.downloadFile(at: dirFileURL)
		})
	}

	private func getDirURL(_ dirId: Data) throws -> URL {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultURL.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])", isDirectory: true)
	}

	private func getDirURL(_ cleartextURL: URL) -> Promise<URL> {
		return getDirId(cleartextURL).then { dirId in
			return try self.getDirURL(dirId)
		}
	}

	private func getCiphertextURL(_ cleartextURL: URL, parentDirId: Data) throws -> URL {
		let ciphertextBaseName = try cryptor.encryptFileName(cleartextURL.lastPathComponent, dirId: parentDirId)
		let ciphertextName = "\(ciphertextBaseName).c9r"
		let isDirectory = cleartextURL.hasDirectoryPath
		return try getDirURL(parentDirId).appendingPathComponent(ciphertextName, isDirectory: isDirectory)
	}

	private func getCiphertextURL(_ cleartextURL: URL) -> Promise<URL> {
		let cleartextParent = cleartextURL.deletingLastPathComponent()
		return getDirId(cleartextParent).then { parentDirId in
			return try self.getCiphertextURL(cleartextURL, parentDirId: parentDirId)
		}
	}

	// MARK: - Decryption

	private func getCleartextMetadata(_ ciphertextMetadata: CloudItemMetadata, cleartextParentURL: URL) -> Promise<CloudItemMetadata> {
		getDirId(cleartextParentURL).then { parentDirId -> CloudItemMetadata in
			guard String(ciphertextMetadata.name.suffix(4)) == ".c9r" else {
				throw VaultFormat7Error.encounteredUnrelatedFile // not a Cryptomator file
			}
			let ciphertextBaseName = String(ciphertextMetadata.name.prefix(ciphertextMetadata.name.count - 4))
			let cleartextName = try self.cryptor.decryptFileName(ciphertextBaseName, dirId: parentDirId)
			let cleartextURL = cleartextParentURL.appendingPathComponent(cleartextName, isDirectory: ciphertextMetadata.itemType == .folder)
			let cleartextSize = 0 // TODO: determine cleartext size
			return CloudItemMetadata(name: cleartextName, remoteURL: cleartextURL, itemType: ciphertextMetadata.itemType, lastModifiedDate: ciphertextMetadata.lastModifiedDate, size: cleartextSize)
		}
	}

	// MARK: - Convenience

	private func downloadFile(at remoteURL: URL) -> Promise<Data> {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return delegate.downloadFile(from: remoteURL, to: localURL, progress: nil).then {
			return try Data(contentsOf: localURL)
		}.always {
			try? FileManager.default.removeItem(at: localURL)
		}
	}

	private func deleteCiphertextDir(_ dirId: Data) -> Promise<Void> {
		let dirURL: URL
		do {
			dirURL = try getDirURL(dirId)
		} catch {
			return Promise(error)
		}
		return delegate.fetchItemListExhaustively(forFolderAt: dirURL).then { itemList in
			let subDirs = itemList.items.filter { $0.remoteURL.hasDirectoryPath }
			let subDirItemListPromises = subDirs.map { self.delegate.fetchItemListExhaustively(forFolderAt: $0.remoteURL) }
			return all(subDirItemListPromises).then { subDirItemLists -> Promise<[Maybe<Data>]> in
				// find subdirectories
				let allDirFiles = subDirItemLists.flatMap { $0.items }.filter { $0.name == "dir.c9r" }
				let dirIdPromises = allDirFiles.map { self.downloadFile(at: $0.remoteURL) }
				return any(dirIdPromises)
			}.then { dirIds -> Promise<[Maybe<Void>]> in
				// delete subdirectories recursively
				let recursiveDeleteOperations = dirIds.filter { $0.value != nil }.map { self.deleteCiphertextDir($0.value!) }
				return any(recursiveDeleteOperations)
			}.then { _ in
				// delete self
				return self.delegate.deleteItem(at: dirURL)
			}
		}
	}
}
