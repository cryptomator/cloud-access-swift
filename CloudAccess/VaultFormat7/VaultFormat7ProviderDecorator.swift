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

private extension URL {
	func appendingMasterkeyFileComponent() -> URL {
		return appendingPathComponent("masterkey.cryptomator", isDirectory: false)
	}

	func appendingDirFileComponent() -> URL {
		return appendingPathComponent("dir.c9r", isDirectory: false)
	}

	func directoryURL() -> URL {
		return deletingLastPathComponent().appendingPathComponent(lastPathComponent, isDirectory: true)
	}
}

/**
 Cloud provider decorator for Cryptomator vaults in vault format 7 (without name shortening).

 With this decorator, you can call the cloud provider methods with cleartext URLs (relative to `vaultURL`) and the decorator passes ciphertext URLs (absolute) to the delegate. It transparently encrypts/decrypts filenames and file contents according to vault format 7, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.5/security/architecture/).

 Use the factory methods to create a new crypto decorator. In order to be fully compatible with vault format 7, pass an instance of `VaultFormat7ShorteningProviderDecorator` (shortening decorator) as the delegate.
 */
public class VaultFormat7ProviderDecorator: CloudProvider {
	let delegate: CloudProvider
	let vaultURL: URL
	let cryptor: Cryptor
	let dirIdCache: DirectoryIdCache
	let tmpDirURL: URL

	init(delegate: CloudProvider, vaultURL: URL, cryptor: Cryptor) throws {
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

	// MARK: - Factory

	/**
	 Creates crypto decorator with a new masterkey.

	 This method does the following:
	 1. Creates a folder at `vaultURL`.
	 2. Uses `password` to create a new masterkey.
	 3. Uploads masterkey file to `masterkey.cryptomator` relative to `vaultURL`.
	 4. Creates a folder at `d/` relative to `vaultURL`.
	 5. Creates a folder at `d/<two-chars>/` relative to `vaultURL`.
	 6. Creates a folder at `d/<two-chars>/<thirty-chars>/` relative to `vaultURL`.

	 - Parameter delegate: The cloud provider that is being decorated.
	 - Parameter vaultURL: The vault URL. Last path component represents the vault name.
	 - Parameter password: The password used to encrypt the key material.
	 - Returns: Promise with the crypto decorator.
	 */
	public static func createNew(delegate: CloudProvider, vaultURL: URL, password: String) -> Promise<VaultFormat7ProviderDecorator> {
		do {
			let masterkey = try Masterkey.createNew()
			let cryptor = Cryptor(masterkey: masterkey)
			let decorator = try VaultFormat7ProviderDecorator(delegate: delegate, vaultURL: vaultURL, cryptor: cryptor)
			let rootDirURL = try decorator.getDirURL(Data())
			let resolvedRootDirURL = URL(fileURLWithPath: rootDirURL.path, relativeTo: vaultURL).directoryURL()
			return delegate.createFolder(at: vaultURL).then { () -> Promise<CloudItemMetadata> in
				let tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
				try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
				let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				let masterkeyData = try masterkey.exportEncrypted(password: password)
				try masterkeyData.write(to: localMasterkeyURL)
				let remoteMasterkeyURL = vaultURL.appendingMasterkeyFileComponent()
				return delegate.uploadFile(from: localMasterkeyURL, to: remoteMasterkeyURL, replaceExisting: false)
			}.then { _ -> Promise<Void> in
				let dURL = vaultURL.appendingPathComponent("d", isDirectory: true)
				return delegate.createFolder(at: dURL)
			}.then { () -> Promise<Void> in
				let twoCharsURL = resolvedRootDirURL.deletingLastPathComponent()
				return delegate.createFolder(at: twoCharsURL)
			}.then { () -> Promise<Void> in
				return delegate.createFolder(at: resolvedRootDirURL)
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
	 1. Downloads masterkey file from `masterkey.cryptomator` relative to `vaultURL`.
	 2. Uses `password` to create a masterkey from downloaded masterkey file. This is equivalent to an unlock attempt.

	 - Parameter delegate: The cloud provider that is being decorated.
	 - Parameter vaultURL: The vault URL. Last path component represents the vault name.
	 - Parameter password: The password to use for decrypting the masterkey file.
	 - Returns: Promise with the crypto decorator.
	 */
	public static func createFromExisting(delegate: CloudProvider, vaultURL: URL, password: String) -> Promise<VaultFormat7ProviderDecorator> {
		do {
			let remoteMasterkeyURL = vaultURL.appendingMasterkeyFileComponent()
			let tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			let localMasterkeyURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			return delegate.downloadFile(from: remoteMasterkeyURL, to: localMasterkeyURL).then { () -> VaultFormat7ProviderDecorator in
				let masterkey = try Masterkey.createFromMasterkeyFile(fileURL: localMasterkeyURL, password: password)
				let cryptor = Cryptor(masterkey: masterkey)
				return try VaultFormat7ProviderDecorator(delegate: delegate, vaultURL: vaultURL, cryptor: cryptor)
			}
		} catch {
			return Promise(error)
		}
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at cleartextURL: URL) -> Promise<CloudItemMetadata> {
		precondition(cleartextURL.isFileURL)
		let cleartextParentURL = cleartextURL.deletingLastPathComponent()
		let parentDirIdPromise = getDirId(cleartextParentURL)
		let ciphertextMetadataPromise = parentDirIdPromise.then { parentDirId in
			return try self.getCiphertextURL(cleartextURL, parentDirId: parentDirId)
		}.then { ciphertextURL in
			return self.delegate.fetchItemMetadata(at: ciphertextURL)
		}
		return all(ciphertextMetadataPromise, parentDirIdPromise).then { ciphertextMetadata, parentDirId in
			try self.toCleartextMetadata(ciphertextMetadata, cleartextParentURL: cleartextURL.deletingLastPathComponent(), parentDirId: parentDirId)
		}
	}

	public func fetchItemList(forFolderAt cleartextURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		precondition(cleartextURL.isFileURL)
		precondition(cleartextURL.hasDirectoryPath)
		let ciphertextListPromise = getDirURL(cleartextURL).then { dirURL in
			return self.delegate.fetchItemList(forFolderAt: dirURL, withPageToken: pageToken)
		}
		return all(ciphertextListPromise, getDirId(cleartextURL)).then { ciphertextList, parentDirId in
			try self.toCleartextList(ciphertextList, cleartextParentURL: cleartextURL, parentDirId: parentDirId)
		}
	}

	public func downloadFile(from remoteCleartextURL: URL, to localCleartextURL: URL) -> Promise<Void> {
		precondition(remoteCleartextURL.isFileURL)
		precondition(localCleartextURL.isFileURL)
		precondition(!remoteCleartextURL.hasDirectoryPath)
		precondition(!localCleartextURL.hasDirectoryPath)
		let overallProgress = Progress(totalUnitCount: 5)
		let localCiphertextURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return getCiphertextURL(remoteCleartextURL).then { remoteCiphertextURL in
			overallProgress.becomeCurrent(withPendingUnitCount: 4)
			let downloadFilePromise = self.delegate.downloadFile(from: remoteCiphertextURL, to: localCiphertextURL)
			overallProgress.resignCurrent()
			return downloadFilePromise
		}.then {
			overallProgress.becomeCurrent(withPendingUnitCount: 1)
			try self.cryptor.decryptContent(from: localCiphertextURL, to: localCleartextURL)
			overallProgress.resignCurrent()
			try? FileManager.default.removeItem(at: localCiphertextURL)
		}
	}

	public func uploadFile(from localCleartextURL: URL, to remoteCleartextURL: URL, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localCleartextURL.isFileURL)
		precondition(remoteCleartextURL.isFileURL)
		precondition(!localCleartextURL.hasDirectoryPath)
		precondition(!remoteCleartextURL.hasDirectoryPath)
		let overallProgress = Progress(totalUnitCount: 5)
		let localCiphertextURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let remoteCleartextParentURL = remoteCleartextURL.deletingLastPathComponent()
		let parentDirIdPromise = getDirId(remoteCleartextParentURL)
		let uploadFilePromise = parentDirIdPromise.then { parentDirId in
			return try self.getCiphertextURL(remoteCleartextURL, parentDirId: parentDirId)
		}.then { remoteCiphertextURL -> Promise<CloudItemMetadata> in
			overallProgress.becomeCurrent(withPendingUnitCount: 1)
			try self.cryptor.encryptContent(from: localCleartextURL, to: localCiphertextURL)
			overallProgress.resignCurrent()
			overallProgress.becomeCurrent(withPendingUnitCount: 4)
			let uploadFilePromise = self.delegate.uploadFile(from: localCiphertextURL, to: remoteCiphertextURL, replaceExisting: replaceExisting)
			overallProgress.resignCurrent()
			return uploadFilePromise
		}.always {
			try? FileManager.default.removeItem(at: localCiphertextURL)
		}
		return all(uploadFilePromise, parentDirIdPromise).then { ciphertextMetadata, parentDirId in
			return try self.toCleartextMetadata(ciphertextMetadata, cleartextParentURL: remoteCleartextURL.deletingLastPathComponent(), parentDirId: parentDirId)
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
			return self.delegate.uploadFile(from: localDirFileURL, to: remoteDirFileURL, replaceExisting: false)
		}.then { _ -> Promise<Void> in
			let parentDirURL = dirURL.deletingLastPathComponent()
			return self.delegate.createFolder(at: parentDirURL)
		}.recover { error -> Promise<Void> in
			switch error {
			case CloudProviderError.itemAlreadyExists:
				return Promise(())
			default:
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
			// TODO: recover from error if `deleteCiphertextDir()` rejects with `CloudProviderError.itemNotFound` and delete item anyway (because the directory is broken anyway)
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
		let cleartextParentURL = cleartextURL.deletingLastPathComponent()
		return getDirId(cleartextParentURL).then { parentDirId in
			return try self.getCiphertextURL(cleartextURL, parentDirId: parentDirId)
		}
	}

	// MARK: - Decryption

	private func toCleartextMetadata(_ ciphertextMetadata: CloudItemMetadata, cleartextParentURL: URL, parentDirId: Data) throws -> CloudItemMetadata {
		guard String(ciphertextMetadata.name.suffix(4)) == ".c9r" else {
			throw VaultFormat7Error.encounteredUnrelatedFile // not a Cryptomator file
		}
		let ciphertextBaseName = String(ciphertextMetadata.name.dropLast(4))
		let cleartextName = try cryptor.decryptFileName(ciphertextBaseName, dirId: parentDirId)
		let cleartextURL = cleartextParentURL.appendingPathComponent(cleartextName, isDirectory: ciphertextMetadata.itemType == .folder)
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
		return CloudItemMetadata(name: cleartextName, remoteURL: cleartextURL, itemType: ciphertextMetadata.itemType, lastModifiedDate: ciphertextMetadata.lastModifiedDate, size: cleartextSize)
	}

	private func toCleartextList(_ ciphertextList: CloudItemList, cleartextParentURL: URL, parentDirId: Data) throws -> CloudItemList {
		let cleartextItems = ciphertextList.items.compactMap { try? self.toCleartextMetadata($0, cleartextParentURL: cleartextParentURL, parentDirId: parentDirId) }
		return CloudItemList(items: cleartextItems, nextPageToken: ciphertextList.nextPageToken)
	}

	// MARK: - Convenience

	private func downloadFile(at remoteURL: URL) -> Promise<Data> {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		return delegate.downloadFile(from: remoteURL, to: localURL).then {
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
