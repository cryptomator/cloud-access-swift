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

public enum VaultFormat7Error: Error {
	case encounteredUnrelatedFile
}

private extension CloudPath {
	func appendingMasterkeyFileComponent() -> CloudPath {
		return appendingPathComponent("masterkey.cryptomator")
	}

	func appendingDirFileComponent() -> CloudPath {
		return appendingPathComponent("dir.c9r")
	}
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 7 (without name shortening).

 With this decorator, you can call the cloud provider methods with cleartext paths (relative to `vaultPath`) and the decorator passes ciphertext paths (absolute) to the delegate. It transparently encrypts/decrypts filenames and file contents according to vault format 7, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.5/security/architecture/).

 Use the factory methods to create a new crypto decorator. In order to be fully compatible with vault format 7, pass an instance of `VaultFormat7ShorteningProviderDecorator` (shortening decorator) as the delegate.
 */
public class VaultFormat7ProviderDecorator: CloudProvider {
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
	 Creates crypto decorator with a new masterkey.

	 This method does the following:
	 1. Creates a folder at `vaultPath`.
	 2. Uses `password` to create a new masterkey.
	 3. Uploads masterkey file to `masterkey.cryptomator` relative to `vaultPath`.
	 4. Creates a folder at `d/` relative to `vaultPath`.
	 5. Creates a folder at `d/<two-chars>/` relative to `vaultPath`.
	 6. Creates a folder at `d/<two-chars>/<thirty-chars>/` relative to `vaultPath`.

	 - Parameter delegate: The cloud provider that is being decorated.
	 - Parameter vaultPath: The vault path. Last path component represents the vault name.
	 - Parameter password: The password used to encrypt the key material.
	 - Returns: Promise with the crypto decorator.
	 */
	public static func createNew(delegate: CloudProvider, vaultPath: CloudPath, password: String) -> Promise<VaultFormat7ProviderDecorator> {
		do {
			let masterkey = try Masterkey.createNew()
			let cryptor = Cryptor(masterkey: masterkey)
			let decorator = try VaultFormat7ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
			let rootDirPath = try decorator.getDirPath(Data())
			return delegate.createFolder(at: vaultPath).then { () -> Promise<CloudItemMetadata> in
				let tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
				try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
				let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				let masterkeyData = try masterkey.exportEncrypted(password: password)
				try masterkeyData.write(to: localMasterkeyURL)
				let masterkeyCloudPath = vaultPath.appendingMasterkeyFileComponent()
				return delegate.uploadFile(from: localMasterkeyURL, to: masterkeyCloudPath, replaceExisting: false)
			}.then { _ -> Promise<Void> in
				let dPath = vaultPath.appendingPathComponent("d/")
				return delegate.createFolder(at: dPath)
			}.then { () -> Promise<Void> in
				let twoCharsPath = rootDirPath.deletingLastPathComponent()
				return delegate.createFolder(at: twoCharsPath)
			}.then { () -> Promise<Void> in
				return delegate.createFolder(at: rootDirPath)
			}.then { () -> VaultFormat7ProviderDecorator in
				return decorator
			}
		} catch {
			return Promise(error)
		}
	}

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
	public static func createFromExisting(delegate: CloudProvider, vaultPath: CloudPath, password: String) -> Promise<VaultFormat7ProviderDecorator> {
		do {
			let masterkeyCloudPath = vaultPath.appendingMasterkeyFileComponent()
			let tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			return delegate.downloadFile(from: masterkeyCloudPath, to: localMasterkeyURL).then { () -> VaultFormat7ProviderDecorator in
				let masterkey = try Masterkey.createFromMasterkeyFile(fileURL: localMasterkeyURL, password: password)
				let cryptor = Cryptor(masterkey: masterkey)
				return try VaultFormat7ProviderDecorator(delegate: delegate, vaultPath: vaultPath, cryptor: cryptor)
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
			return try self.getCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
		}.then { ciphertextPath in
			return self.delegate.fetchItemMetadata(at: ciphertextPath)
		}
		return all(ciphertextMetadataPromise, parentDirIdPromise).then { ciphertextMetadata, parentDirId in
			try self.toCleartextMetadata(ciphertextMetadata, cleartextParentPath: cleartextCloudPath.deletingLastPathComponent(), parentDirId: parentDirId)
		}
	}

	public func fetchItemList(forFolderAt cleartextCloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		precondition(cleartextCloudPath.hasDirectoryPath)
		let ciphertextListPromise = getDirPath(cleartextCloudPath).then { dirPath in
			return self.delegate.fetchItemList(forFolderAt: dirPath, withPageToken: pageToken)
		}
		return all(ciphertextListPromise, getDirId(cleartextCloudPath)).then { ciphertextList, parentDirId in
			try self.toCleartextList(ciphertextList, cleartextParentPath: cleartextCloudPath, parentDirId: parentDirId)
		}
	}

	public func downloadFile(from cleartextCloudPath: CloudPath, to cleartextLocalURL: URL) -> Promise<Void> {
		precondition(cleartextLocalURL.isFileURL)
		precondition(!cleartextCloudPath.hasDirectoryPath)
		precondition(!cleartextLocalURL.hasDirectoryPath)
		let overallProgress = Progress(totalUnitCount: 5)
		let ciphertextLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return getCiphertextPath(cleartextCloudPath).then { ciphertextCloudPath in
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
		precondition(!cleartextLocalURL.hasDirectoryPath)
		precondition(!cleartextCloudPath.hasDirectoryPath)
		let overallProgress = Progress(totalUnitCount: 5)
		let ciphertextLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let cleartextParentCloudPath = cleartextCloudPath.deletingLastPathComponent()
		let parentDirIdPromise = getDirId(cleartextParentCloudPath)
		let uploadFilePromise = parentDirIdPromise.then { parentDirId in
			return try self.getCiphertextPath(cleartextCloudPath, parentDirId: parentDirId)
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
		precondition(cleartextCloudPath.hasDirectoryPath)
		let dirId = UUID().uuidString.data(using: .utf8)!
		let localDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let dirPath: CloudPath
		do {
			try dirId.write(to: localDirFileURL)
			dirPath = try getDirPath(dirId)
		} catch {
			return Promise(error)
		}
		let ciphertextPathPromise = getCiphertextPath(cleartextCloudPath)
		return ciphertextPathPromise.then { ciphertextCloudPath in
			return self.delegate.createFolder(at: ciphertextCloudPath)
		}.then { ciphertextPathPromise }.then { ciphertextCloudPath -> Promise<CloudItemMetadata> in
			let dirFileCloudPath = ciphertextCloudPath.appendingDirFileComponent()
			return self.delegate.uploadFile(from: localDirFileURL, to: dirFileCloudPath, replaceExisting: false)
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

	public func deleteItem(at cleartextCloudPath: CloudPath) -> Promise<Void> {
		if cleartextCloudPath.hasDirectoryPath {
			// TODO: recover from error if `getDirId()` rejects with `CloudProviderError.itemNotFound` and delete item anyway (because it's probably a symlink)
			// TODO: recover from error if `deleteCiphertextDir()` rejects with `CloudProviderError.itemNotFound` and delete item anyway (because the directory is broken anyway)
			return getDirId(cleartextCloudPath).then { dirId in
				return self.deleteCiphertextDir(dirId)
			}.then {
				return self.getCiphertextPath(cleartextCloudPath)
			}.then { ciphertextCloudPath in
				return self.delegate.deleteItem(at: ciphertextCloudPath)
			}
		} else {
			return getCiphertextPath(cleartextCloudPath).then { ciphertextCloudPath in
				return self.delegate.deleteItem(at: ciphertextCloudPath)
			}
		}
	}

	public func moveItem(from cleartextSourceCloudPath: CloudPath, to cleartextTargetCloudPath: CloudPath) -> Promise<Void> {
		precondition(cleartextSourceCloudPath.hasDirectoryPath == cleartextTargetCloudPath.hasDirectoryPath)
		return all(getCiphertextPath(cleartextSourceCloudPath), getCiphertextPath(cleartextTargetCloudPath)).then { ciphertextSourceCloudPath, ciphertextTargetCloudPath in
			return self.delegate.moveItem(from: ciphertextSourceCloudPath, to: ciphertextTargetCloudPath)
		}
	}

	// MARK: - Encryption

	private func getDirId(_ cleartextPath: CloudPath) -> Promise<Data> {
		return dirIdCache.get(cleartextPath, onMiss: { cleartextPath, parentDirId in
			let ciphertextPath = try self.getCiphertextPath(cleartextPath, parentDirId: parentDirId)
			let dirFilePath = ciphertextPath.appendingDirFileComponent()
			return self.downloadFile(at: dirFilePath)
		})
	}

	private func getDirPath(_ dirId: Data) throws -> CloudPath {
		let digest = try cryptor.encryptDirId(dirId)
		let i = digest.index(digest.startIndex, offsetBy: 2)
		return vaultPath.appendingPathComponent("d/\(digest[..<i])/\(digest[i...])/")
	}

	private func getDirPath(_ cleartextPath: CloudPath) -> Promise<CloudPath> {
		return getDirId(cleartextPath).then { dirId in
			return try self.getDirPath(dirId)
		}
	}

	private func getCiphertextPath(_ cleartextPath: CloudPath, parentDirId: Data) throws -> CloudPath {
		let ciphertextBaseName = try cryptor.encryptFileName(cleartextPath.lastPathComponent, dirId: parentDirId)
		let ciphertextName = "\(ciphertextBaseName).c9r"
		return try getDirPath(parentDirId).appendingPathComponent("\(ciphertextName)\(cleartextPath.hasDirectoryPath ? "/" : "")")
	}

	private func getCiphertextPath(_ cleartextPath: CloudPath) -> Promise<CloudPath> {
		let cleartextParentPath = cleartextPath.deletingLastPathComponent()
		return getDirId(cleartextParentPath).then { parentDirId in
			return try self.getCiphertextPath(cleartextPath, parentDirId: parentDirId)
		}
	}

	// MARK: - Decryption

	private func toCleartextMetadata(_ ciphertextMetadata: CloudItemMetadata, cleartextParentPath: CloudPath, parentDirId: Data) throws -> CloudItemMetadata {
		guard String(ciphertextMetadata.name.suffix(4)) == ".c9r" else {
			throw VaultFormat7Error.encounteredUnrelatedFile // not a Cryptomator file
		}
		let ciphertextBaseName = String(ciphertextMetadata.name.dropLast(4))
		let cleartextName = try cryptor.decryptFileName(ciphertextBaseName, dirId: parentDirId)
		let isDirectory = ciphertextMetadata.itemType == .folder
		let cleartextPath = cleartextParentPath.appendingPathComponent("\(cleartextName)\(isDirectory ? "/" : "")")
		let cleartextSize = try { () -> Int? in
			guard let ciphertextSize = ciphertextMetadata.size else {
				return nil
			}
			if ciphertextMetadata.itemType == .file {
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
			let subDirs = itemList.items.filter { $0.cloudPath.hasDirectoryPath }
			let subDirItemListPromises = subDirs.map { self.delegate.fetchItemListExhaustively(forFolderAt: $0.cloudPath) }
			return all(subDirItemListPromises).then { subDirItemLists -> Promise<[Maybe<Data>]> in
				// find subdirectories
				let allDirFiles = subDirItemLists.flatMap { $0.items }.filter { $0.name == "dir.c9r" }
				let dirIdPromises = allDirFiles.map { self.downloadFile(at: $0.cloudPath) }
				return any(dirIdPromises)
			}.then { dirIds -> Promise<[Maybe<Void>]> in
				// delete subdirectories recursively
				let recursiveDeleteOperations = dirIds.filter { $0.value != nil }.map { self.deleteCiphertextDir($0.value!) }
				return any(recursiveDeleteOperations)
			}.then { _ in
				// delete self
				return self.delegate.deleteItem(at: dirPath)
			}
		}
	}
}
