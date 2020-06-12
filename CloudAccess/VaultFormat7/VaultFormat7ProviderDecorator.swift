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
			let dirURL = try self.getDirURL(dirId)
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
		let localCiphertextURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		return getCiphertextURL(remoteCleartextURL).then { remoteCiphertextURL in
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
		return getDirFileURL(cleartextURL: cleartextURL).then { remoteDirFileURL in
			return self.delegate.uploadFile(from: localDirFileURL, to: remoteDirFileURL, replaceExisting: false, progress: nil)
		}.then { _ in
			let dirURL = try self.getDirURL(dirId)
			return self.delegate.createFolderWithIntermediates(at: dirURL)
		}.always {
			try? FileManager.default.removeItem(at: localDirFileURL)
		}
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
			ciphertextDir = try getDirURL(dirId)
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
			let ciphertextParentPath = try self.getDirURL(dirId)
			let ciphertextName = try self.cryptor.encryptFileName(cleartextName, dirId: dirId)
			return Promise(ciphertextParentPath.appendingPathComponent(ciphertextName + ".c9r", isDirectory: cleartextURL.hasDirectoryPath))
		}
	}

	private func getDirId(cleartextURL: URL) -> Promise<Data> {
		return dirIdCache.get(cleartextURL, onMiss: { url, parentDirId in
			let dirFileURL = try self.getDirFileURL(cleartextURL: url, parentDirId: parentDirId)
			return self.getRemoteFileContents(dirFileURL)
		})
	}

	private func getDirFileURL(cleartextURL: URL) -> Promise<URL> {
		return getDirId(cleartextURL: cleartextURL.deletingLastPathComponent()).then { parentDirId in
			return try self.getDirFileURL(cleartextURL: cleartextURL, parentDirId: parentDirId)
		}
	}

	private func getDirFileURL(cleartextURL: URL, parentDirId: Data) throws -> URL {
		let ciphertextName = try cryptor.encryptFileName(cleartextURL.lastPathComponent, dirId: parentDirId)
		return try getDirURL(parentDirId).appendingPathComponent(ciphertextName + ".c9r/dir.c9r")
	}

	private func getRemoteFileContents(_ remoteURL: URL) -> Promise<Data> {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		return delegate.downloadFile(from: remoteURL, to: localURL, progress: nil).then {
			return try Data(contentsOf: localURL)
		}.always {
			try? FileManager.default.removeItem(at: localURL)
		}
	}

	private func getDirURL(_ dirId: Data) throws -> URL {
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
