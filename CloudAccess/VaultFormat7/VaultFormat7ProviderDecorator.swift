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

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cleartextURL: URL) -> Promise<CloudItemMetadata> {
		precondition(cleartextURL.isFileURL)
		return ciphertextURL(cleartextURL).then { ciphertextURL in
			return self.delegate.fetchItemMetadata(at: ciphertextURL)
		}.then { ciphertextMetadata in
			return self.cleartextMetadata(ciphertextMetadata, cleartextParentURL: cleartextURL.deletingLastPathComponent())
		}
	}

	public func fetchItemList(forFolderAt cleartextURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		precondition(cleartextURL.isFileURL)
		precondition(cleartextURL.hasDirectoryPath)
		return dirId(cleartextURL: cleartextURL).then { dirId -> Promise<CloudItemList> in
			let dirURL = try self.dirURL(dirId)
			return self.delegate.fetchItemList(forFolderAt: dirURL, withPageToken: pageToken)
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
		return ciphertextURL(remoteCleartextURL).then { remoteCiphertextURL in
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
		let localCiphertextURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		return ciphertextURL(remoteCleartextURL).then { remoteCiphertextURL in
			try self.cryptor.encryptContent(from: localCleartextURL, to: localCiphertextURL)
			return self.delegate.uploadFile(from: localCiphertextURL, to: remoteCiphertextURL, replaceExisting: replaceExisting, progress: progress)
		}.always {
			try? FileManager.default.removeItem(at: localCiphertextURL)
		}
	}

	public func createFolder(at cleartextURL: URL) -> Promise<Void> {
		precondition(cleartextURL.isFileURL)
		precondition(cleartextURL.hasDirectoryPath)
		let dirId = UUID().uuidString.data(using: .utf8)!
		let localDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		do {
			try dirId.write(to: localDirFileURL)
		} catch {
			return Promise(error)
		}
		return dirFileURL(cleartextURL: cleartextURL).then { remoteDirFileURL in
			return self.delegate.uploadFile(from: localDirFileURL, to: remoteDirFileURL, replaceExisting: false, progress: nil)
		}.then { _ -> Promise<Void> in
			let parentDirURL = try self.dirURL(dirId).deletingLastPathComponent()
			return self.delegate.createFolder(at: parentDirURL)
		}.recover { error -> Promise<Void> in
			if case CloudProviderError.itemAlreadyExists = error {
				return Promise(())
			} else {
				return Promise(error)
			}
		}.then { () -> Promise<Void> in
			let dirURL = try self.dirURL(dirId)
			return self.delegate.createFolder(at: dirURL)
		}.always {
			try? FileManager.default.removeItem(at: localDirFileURL)
		}
	}

	public func deleteItem(at cleartextURL: URL) -> Promise<Void> {
		precondition(cleartextURL.isFileURL)
		if cleartextURL.hasDirectoryPath {
			return dirId(cleartextURL: cleartextURL).then { dirId in
				return self.deleteCiphertextDir(dirId)
			}.then {
				return self.ciphertextURL(cleartextURL)
			}.then { ciphertextURL in
				return self.delegate.deleteItem(at: ciphertextURL)
			}
		} else {
			return ciphertextURL(cleartextURL).then { ciphertextURL in
				return self.delegate.deleteItem(at: ciphertextURL)
			}
		}
	}

	public func moveItem(from oldCleartextURL: URL, to newCleartextURL: URL) -> Promise<Void> {
		precondition(oldCleartextURL.isFileURL)
		precondition(newCleartextURL.isFileURL)
		precondition(oldCleartextURL.hasDirectoryPath == newCleartextURL.hasDirectoryPath)
		return all(
			ciphertextURL(oldCleartextURL),
			ciphertextURL(newCleartextURL)
		).then { oldCiphertextURL, newCiphertextURL in
			return self.delegate.moveItem(from: oldCiphertextURL, to: newCiphertextURL)
		}
	}

	// MARK: - Conversion

	private func ciphertextURL(_ cleartextURL: URL) -> Promise<URL> {
		let cleartextParent = cleartextURL.deletingLastPathComponent()
		let cleartextName = cleartextURL.lastPathComponent
		return dirId(cleartextURL: cleartextParent).then { dirId in
			let ciphertextParentPath = try self.dirURL(dirId)
			let ciphertextName = try self.cryptor.encryptFileName(cleartextName, dirId: dirId)
			return Promise(ciphertextParentPath.appendingPathComponent(ciphertextName + ".c9r", isDirectory: cleartextURL.hasDirectoryPath))
		}
	}

	private func cleartextMetadata(_ ciphertextMetadata: CloudItemMetadata, cleartextParentURL: URL) -> Promise<CloudItemMetadata> {
		dirId(cleartextURL: cleartextParentURL).then { parentDirId in
			// TODO: unshorten .c9s names
			guard let extRange = ciphertextMetadata.name.range(of: ".c9r", options: .caseInsensitive) else {
				throw VaultFormat7Error.encounteredUnrelatedFile // not a Cryptomator file
			}
			let ciphertextName = String(ciphertextMetadata.name[..<extRange.lowerBound])
			let cleartextName = try self.cryptor.decryptFileName(ciphertextName, dirId: parentDirId)
			let cleartextURL = cleartextParentURL.appendingPathComponent(cleartextName, isDirectory: ciphertextMetadata.itemType == .folder)
			let cleartextSize = 0 // TODO: determine cleartext size
			return Promise(CloudItemMetadata(name: cleartextName, remoteURL: cleartextURL, itemType: ciphertextMetadata.itemType, lastModifiedDate: ciphertextMetadata.lastModifiedDate, size: cleartextSize)) // TODO: determine itemType
		}
	}

	// MARK: - Directory

	private func dirURL(_ dirId: Data) throws -> URL {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultURL.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])", isDirectory: true)
	}

	private func dirFileURL(cleartextURL: URL, parentDirId: Data) throws -> URL {
		let ciphertextName = try cryptor.encryptFileName(cleartextURL.lastPathComponent, dirId: parentDirId)
		return try dirURL(parentDirId).appendingPathComponent("\(ciphertextName).c9r/dir.c9r")
	}

	private func dirFileURL(cleartextURL: URL) -> Promise<URL> {
		return dirId(cleartextURL: cleartextURL.deletingLastPathComponent()).then { parentDirId in
			return try self.dirFileURL(cleartextURL: cleartextURL, parentDirId: parentDirId)
		}
	}

	private func dirId(cleartextURL: URL) -> Promise<Data> {
		return dirIdCache.get(cleartextURL, onMiss: { url, parentDirId in
			let dirFileURL = try self.dirFileURL(cleartextURL: url, parentDirId: parentDirId)
			return self.downloadFile(at: dirFileURL)
		})
	}

	// MARK: - Convenience

	private func downloadFile(at remoteURL: URL) -> Promise<Data> {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		return delegate.downloadFile(from: remoteURL, to: localURL, progress: nil).then {
			return try Data(contentsOf: localURL)
		}.always {
			try? FileManager.default.removeItem(at: localURL)
		}
	}

	private func deleteCiphertextDir(_ dirId: Data) -> Promise<Void> {
		let ciphertextDir: URL
		do {
			ciphertextDir = try dirURL(dirId)
		} catch {
			return Promise(error)
		}
		return delegate.fetchItemListExhaustively(forFolderAt: ciphertextDir).then { ciphertextItemList in
			let subDirs = ciphertextItemList.items.filter { $0.remoteURL.hasDirectoryPath }
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
				return self.delegate.deleteItem(at: ciphertextDir)
			}
		}
	}
}
