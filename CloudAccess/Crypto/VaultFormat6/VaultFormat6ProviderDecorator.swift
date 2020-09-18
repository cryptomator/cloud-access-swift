//
//  VaultFormat6ProviderDecorator.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import Promises

private extension CloudPath {
	func appendingMasterkeyFileComponent() -> CloudPath {
		return appendingPathComponent("masterkey.cryptomator")
	}
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 6 (without name shortening).

 With this decorator, you can call the cloud provider methods with cleartext paths (relative to `vaultPath`) and the decorator passes ciphertext paths (absolute) to the delegate. It transparently encrypts/decrypts filenames and file contents according to vault format 6, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.4/security/architecture/).

 Use the factory methods to create a new crypto decorator. In order to be fully compatible with vault format 6, pass an instance of `VaultFormat6ShorteningProviderDecorator` (shortening decorator) as the delegate.
 */
public class VaultFormat6ProviderDecorator: CloudProvider {
	let delegate: CloudProvider
	let vaultPath: CloudPath
	let cryptor: Cryptor
	let dirIdCache: DirectoryIdCache
	let tmpDirURL: URL

	init(delegate: CloudProvider, vaultPath: CloudPath, cryptor: Cryptor) throws {
		self.delegate = delegate
		self.vaultPath = vaultPath
		self.cryptor = cryptor
		self.dirIdCache = try DirectoryIdCache()
		self.tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - Factory

	/**
	 Creates crypto decorator from an existing masterkey.

	 This method does the following:
	 1. Downloads masterkey file from `masterkey.cryptomator` relative to `vaultPath`.
	 2. Uses `password` to create a masterkey from downloaded masterkey file. This is equivalent to an unlock attempt.

	 - Parameter delegate: The cloud provider that is being decorated.
	 - Parameter vaultPath: The vault path. Last path component represents the vault name.
	 - Parameter password: The password to use for decrypting the masterkey file.
	 - Returns: Promise with the crypto decorator.
	 */
	public static func createFromExisting(delegate: CloudProvider, vaultPath: CloudPath, password: String) -> Promise<VaultFormat6ProviderDecorator> {
		do {
			let masterkeyCloudPath = vaultPath.appendingMasterkeyFileComponent()
			let tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			return delegate.downloadFile(from: masterkeyCloudPath, to: localMasterkeyURL).then { () -> VaultFormat6ProviderDecorator in
				let masterkey = try Masterkey.createFromMasterkeyFile(fileURL: localMasterkeyURL, password: password)
				let cryptor = Cryptor(masterkey: masterkey)
				return try VaultFormat6ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
			}
		} catch {
			return Promise(error)
		}
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cleartextCloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let cleartextParentPath = cleartextCloudPath.deletingLastPathComponent()
		let parentDirIdPromise = getDirId(cleartextParentPath)
		let ciphertextMetadataPromise = parentDirIdPromise.then { parentDirId in
			return try self.getFileCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		}.then { ciphertextPath in
			return self.delegate.fetchItemMetadata(at: ciphertextPath)
		}.recover { error -> Promise<CloudItemMetadata> in
			switch error {
			case CloudProviderError.itemNotFound:
				return parentDirIdPromise.then { parentDirId in
					return try self.getFolderCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
				}.then { ciphertextPath in
					return self.delegate.fetchItemMetadata(at: ciphertextPath)
				}
			default:
				return Promise(error)
			}
		}
		return all(ciphertextMetadataPromise, parentDirIdPromise).then { ciphertextMetadata, parentDirId in
			try self.toCleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		}
	}

	public func fetchItemList(forFolderAt cleartextCloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let ciphertextListPromise = getDirPath(cleartextCloudPath).then { dirPath in
			return self.delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		}
		return all(ciphertextListPromise, getDirId(cleartextCloudPath)).then { ciphertextList, parentDirId in
			try self.toCleartextList(ciphertextList, cleartextParentPath: cleartextCloudPath, parentDirId: parentDirId)
		}
	}

	public func downloadFile(from cleartextCloudPath: CloudPath, to cleartextLocalURL: URL) -> Promise<Void> {
		precondition(cleartextLocalURL.isFileURL)
		let overallProgress = Progress(totalUnitCount: 5)
		let ciphertextLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return getFileCiphertextPath(cleartextCloudPath).then { ciphertextCloudPath in
			overallProgress.becomeCurrent(withPendingUnitCount: 4)
			let downloadFilePromise = self.delegate.downloadFile(from: ciphertextCloudPath, to: ciphertextLocalURL)
			overallProgress.resignCurrent()
			return downloadFilePromise
		}.then {
			overallProgress.becomeCurrent(withPendingUnitCount: 1)
			try self.cryptor.decryptContent(from: ciphertextLocalURL, to: cleartextLocalURL)
			overallProgress.resignCurrent()
			try? FileManager.default.removeItem(at: ciphertextLocalURL)
		}
	}

	public func uploadFile(from cleartextLocalURL: URL, to cleartextCloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(cleartextLocalURL.isFileURL)
		let overallProgress = Progress(totalUnitCount: 5)
		let ciphertextLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let cleartextParentCloudPath = cleartextCloudPath.deletingLastPathComponent()
		let parentDirIdPromise = getDirId(cleartextParentCloudPath)
		let uploadFilePromise = parentDirIdPromise.then { parentDirId in
			return try self.getFileCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		}.then { ciphertextCloudPath -> Promise<CloudItemMetadata> in
			overallProgress.becomeCurrent(withPendingUnitCount: 1)
			try self.cryptor.encryptContent(from: cleartextLocalURL, to: ciphertextLocalURL)
			overallProgress.resignCurrent()
			overallProgress.becomeCurrent(withPendingUnitCount: 4)
			let uploadFilePromise = self.delegate.uploadFile(from: ciphertextLocalURL, to: ciphertextCloudPath, replaceExisting: replaceExisting)
			overallProgress.resignCurrent()
			return uploadFilePromise
		}.always {
			try? FileManager.default.removeItem(at: ciphertextLocalURL)
		}
		return all(uploadFilePromise, parentDirIdPromise).then { ciphertextMetadata, parentDirId in
			return try self.toCleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		}
	}

	public func createFolder(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		let dirId = UUID().uuidString.data(using: .utf8)!
		let localDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let dirPath: CloudPath
		do {
			try dirId.write(to: localDirFileURL)
			dirPath = try getDirPath(dirId)
		} catch {
			return Promise(error)
		}
		return getFolderCiphertextPath(cleartextCloudPath).then { ciphertextCloudPath in
			return self.delegate.uploadFile(from: localDirFileURL, to: ciphertextCloudPath, replaceExisting: false)
		}.then { _ -> Promise<Void> in
			let parentDirPath = dirPath.deletingLastPathComponent()
			return self.delegate.createFolder(at: parentDirPath)
		}.recover { error -> Promise<Void> in
			switch error {
			case CloudProviderError.itemAlreadyExists:
				return Promise(())
			default:
				return Promise(error)
			}
		}.then { () -> Promise<Void> in
			return self.delegate.createFolder(at: dirPath)
		}.always {
			try? FileManager.default.removeItem(at: localDirFileURL)
		}
	}

	public func deleteFile(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		return getFileCiphertextPath(cleartextCloudPath).then { ciphertextCloudPath in
			return self.delegate.deleteFile(at: ciphertextCloudPath)
		}
	}

	public func deleteFolder(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		// TODO: recover from error if `getDirId()` rejects with `CloudProviderError.itemNotFound` and delete item anyway (because it's probably a symlink)
		// TODO: recover from error if `deleteCiphertextDir()` rejects with `CloudProviderError.itemNotFound` and delete item anyway (because the directory is broken anyway)
		return getDirId(cleartextCloudPath).then { dirId in
			return self.deleteCiphertextDir(dirId)
		}.then {
			return self.getFolderCiphertextPath(cleartextCloudPath)
		}.then { ciphertextCloudPath in
			return self.delegate.deleteFolder(at: ciphertextCloudPath)
		}
	}

	public func moveFile(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) -> Promise<Void> {
		return all(getFileCiphertextPath(cleartextSourceCloudPath), getFileCiphertextPath(cleartextTargetCloudPath)).then { ciphertextSourceCloudPath, ciphertextTargetCloudPath in
			return self.delegate.moveFile(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
		}
	}

	public func moveFolder(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) -> Promise<Void> {
		return all(getFolderCiphertextPath(cleartextSourceCloudPath), getFolderCiphertextPath(cleartextTargetCloudPath)).then { ciphertextSourceCloudPath, ciphertextTargetCloudPath in
			return self.delegate.moveFolder(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
		}
	}

	// MARK: - Encryption

	private func getDirId(_ cleartextPath: CloudPath) -> Promise<Data> {
		return dirIdCache.get(cleartextPath, onMiss: { cleartextPath, parentDirId in
			let ciphertextPath = try self.getFolderCiphertextPath(cleartextPath, parentDirId: parentDirId)
			return self.downloadFile(at: ciphertextPath)
		})
	}

	private func getDirPath(_ dirId: Data) throws -> CloudPath {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultPath.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])")
	}

	private func getDirPath(_ cleartextPath: CloudPath) -> Promise<CloudPath> {
		return getDirId(cleartextPath).then { dirId in
			return try self.getDirPath(dirId)
		}
	}

	private func getFileCiphertextPath(_ cleartextPath: CloudPath, parentDirId: Data) throws -> CloudPath {
		let ciphertextName = try cryptor.encryptFileName(cleartextPath.lastPathComponent, dirId: parentDirId, encoding: .base32)
		return try getDirPath(parentDirId).appendingPathComponent(ciphertextName)
	}

	private func getFileCiphertextPath(_ cleartextPath: CloudPath) -> Promise<CloudPath> {
		let cleartextParentPath = cleartextPath.deletingLastPathComponent()
		return getDirId(cleartextParentPath).then { parentDirId in
			return try self.getFileCiphertextPath(cleartextPath, parentDirId: parentDirId)
		}
	}

	private func getFolderCiphertextPath(_ cleartextPath: CloudPath, parentDirId: Data) throws -> CloudPath {
		let ciphertextBaseName = try cryptor.encryptFileName(cleartextPath.lastPathComponent, dirId: parentDirId, encoding: .base32)
		let ciphertextName = "0\(ciphertextBaseName)"
		return try getDirPath(parentDirId).appendingPathComponent(ciphertextName)
	}

	private func getFolderCiphertextPath(_ cleartextPath: CloudPath) -> Promise<CloudPath> {
		let cleartextParentPath = cleartextPath.deletingLastPathComponent()
		return getDirId(cleartextParentPath).then { parentDirId in
			return try self.getFolderCiphertextPath(cleartextPath, parentDirId: parentDirId)
		}
	}

	// MARK: - Decryption

	private func toCleartextMetadata(_ ciphertextMetadata: CloudItemMetadata, cleartextParentPath: CloudPath, parentDirId: Data) throws -> CloudItemMetadata {
		let itemType = { () -> CloudItemType in
			if ciphertextMetadata.name.hasPrefix("0") {
				return .folder
			} else if ciphertextMetadata.name.hasPrefix("1S") {
				return .symlink
			} else {
				return .file
			}
		}()
		let ciphertextBaseName = { () -> String in
			switch itemType {
			case .folder:
				return String(ciphertextMetadata.name.dropFirst())
			case .symlink:
				return String(ciphertextMetadata.name.dropFirst(2))
			default:
				return ciphertextMetadata.name
			}
		}()
		let cleartextName = try cryptor.decryptFileName(ciphertextBaseName, dirId: parentDirId, encoding: .base32)
		let cleartextPath = cleartextParentPath.appendingPathComponent(cleartextName)
		let cleartextSize = try { () -> Int? in
			guard let ciphertextSize = ciphertextMetadata.size else {
				return nil
			}
			if itemType == .file || itemType == .symlink {
				return try self.cryptor.calculateCleartextSize(ciphertextSize)
			} else {
				return ciphertextSize
			}
		}()
		return CloudItemMetadata(name: cleartextName, cloudPath: cleartextPath, itemType: ciphertextMetadata.itemType, lastModifiedDate: ciphertextMetadata.lastModifiedDate, size: cleartextSize)
	}

	private func toCleartextList(_ ciphertextList: CloudItemList, cleartextParentPath: CloudPath, parentDirId: Data) throws -> CloudItemList {
		let cleartextItems = ciphertextList.items.compactMap { try? self.toCleartextMetadata($0, cleartextParentPath: cleartextParentPath, parentDirId: parentDirId) }
		return CloudItemList(items: cleartextItems, nextPageToken: ciphertextList.nextPageToken)
	}

	// MARK: - Convenience

	private func downloadFile(at cloudPath: CloudPath) -> Promise<Data> {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return delegate.downloadFile(from: cloudPath, to: localURL).then {
			return try Data(contentsOf: localURL)
		}.always {
			try? FileManager.default.removeItem(at: localURL)
		}
	}

	private func deleteCiphertextDir(_ dirId: Data) -> Promise<Void> {
		let dirPath: CloudPath
		do {
			dirPath = try getDirPath(dirId)
		} catch {
			return Promise(error)
		}
		return delegate.fetchItemListExhaustively(forFolderAt: dirPath).then { itemList in
			let subDirs = itemList.items.filter { $0.name.hasPrefix("0") }
			let dirIdPromises = subDirs.map { self.downloadFile(at: $0.cloudPath) }
			return any(dirIdPromises).then { dirIds -> Promise<[Maybe<Void>]> in
				// delete subdirectories recursively
				let recursiveDeleteOperations = dirIds.filter { $0.value != nil }.map { self.deleteCiphertextDir($0.value!) }
				return any(recursiveDeleteOperations)
			}.then { _ in
				// delete self
				return self.delegate.deleteFolder(at: dirPath)
			}
		}
	}
}
