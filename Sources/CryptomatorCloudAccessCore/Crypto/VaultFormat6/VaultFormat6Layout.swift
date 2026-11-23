//
//  VaultFormat6Layout.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation

/// Cloud provider decorator for Cryptomator vaults in vault format 6 (without name shortening). To be fully compatible with vault format 6, stack it onto a `VaultFormat6ShorteningProviderDecorator`.
typealias VaultFormat6ProviderDecorator = VaultProviderDecorator<VaultFormat6Layout>

/// Splits a listed vault format 6 ciphertext name into the encrypted name and the item type that its prefix marks: `0` for a folder's dir file, `1S` for a symlink, none for a file.
func parseVaultFormat6CiphertextName(_ ciphertextName: String) -> (baseName: String, itemType: CloudItemType) {
	if let baseName = ciphertextName.removingUTF8Prefix("0") {
		return (baseName, .folder)
	} else if let baseName = ciphertextName.removingUTF8Prefix("1S") {
		return (baseName, .symlink)
	} else {
		return (ciphertextName, .file)
	}
}

/**
 The ciphertext layout of vault format 6, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.4/security/architecture/): Base32 names, and a folder's dir ID in a dir file named like the folder with a `0` prefix.

 A folder delete lists the directories below the shortening decorator and reads a `.lng` name file only to tell whether the item is a dir file. A dir file whose name file can't be read therefore fails its item and keeps its parent. A listing through the shortening decorator would leave it out, which would orphan its directory. A legacy `.lng` dir file is followed where it lies, without moving it to its original name. A dir file that a download reaches through an alias fails its item.
 */
struct VaultFormat6Layout: VaultLayout {
	typealias Shortening = VaultFormat6ShorteningProviderDecorator

	var fileNameEncoding: FileNameEncoding {
		return .base32
	}

	func readDirId(_ cleartextPath: CloudPath, parentDirId: Data, refusingAlias: Bool, in decorator: VaultFormat6ProviderDecorator) async throws -> Data {
		let folderCiphertextPath = try folderReferencePath(cleartextPath, parentDirId: parentDirId, in: decorator)
		do {
			return try await decorator.delegate.downloadDirFile(at: folderCiphertextPath, refusingAlias: refusingAlias)
		} catch CloudProviderError.itemNotFound {
			let fileCiphertextPath = try fileCiphertextPath(cleartextPath, parentDirId: parentDirId, in: decorator)
			try Task.checkCancellation()
			if try await decorator.delegate.checkForItemExistence(at: fileCiphertextPath) {
				// ciphertext file exists but ciphertext folder (with `0` prefix) does not
				// symlink existence check has been omitted for simplicity
				throw CloudProviderError.itemTypeMismatch
			} else {
				throw CloudProviderError.itemNotFound
			}
		}
	}

	func fileCiphertextPath(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultFormat6ProviderDecorator) throws -> CloudPath {
		let ciphertextName = try decorator.ciphertextName(of: cleartextPath, parentDirId: parentDirId)
		return try decorator.dirPath(of: parentDirId).appendingPathComponent(ciphertextName)
	}

	func folderReferencePath(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultFormat6ProviderDecorator) throws -> CloudPath {
		let ciphertextBaseName = try decorator.ciphertextName(of: cleartextPath, parentDirId: parentDirId)
		return try decorator.dirPath(of: parentDirId).appendingPathComponent("0\(ciphertextBaseName)")
	}

	/// A folder's metadata is that of its dir file, which is read once no file of the name exists.
	func fetchCiphertextMetadata(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultFormat6ProviderDecorator) async throws -> CloudItemMetadata {
		let fileCiphertextPath = try fileCiphertextPath(cleartextPath, parentDirId: parentDirId, in: decorator)
		try Task.checkCancellation()
		do {
			return try await decorator.delegate.fetchItemMetadata(at: fileCiphertextPath)
		} catch CloudProviderError.itemNotFound {
			let folderCiphertextPath = try folderReferencePath(cleartextPath, parentDirId: parentDirId, in: decorator)
			try Task.checkCancellation()
			return try await decorator.delegate.fetchItemMetadata(at: folderCiphertextPath)
		}
	}

	/// Throws `CloudProviderError.itemTypeMismatch` for a folder of the name.
	func downloadCiphertextFile(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultFormat6ProviderDecorator, using download: (CloudPath) async throws -> CloudItemMetadata) async throws -> CloudItemMetadata {
		let fileCiphertextPath = try fileCiphertextPath(cleartextPath, parentDirId: parentDirId, in: decorator)
		try Task.checkCancellation()
		do {
			return try await download(fileCiphertextPath)
		} catch CloudProviderError.itemNotFound {
			let folderCiphertextPath = try folderReferencePath(cleartextPath, parentDirId: parentDirId, in: decorator)
			try Task.checkCancellation()
			if try await decorator.delegate.checkForItemExistence(at: folderCiphertextPath) {
				throw CloudProviderError.itemTypeMismatch
			} else {
				throw CloudProviderError.itemNotFound
			}
		}
	}

	/// A file and a folder of the same name have different ciphertext names, so the upload checks that no folder holds the name.
	func checkUploadTarget(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultFormat6ProviderDecorator) async throws {
		let folderCiphertextPath = try folderReferencePath(cleartextPath, parentDirId: parentDirId, in: decorator)
		try Task.checkCancellation()
		if try await decorator.delegate.checkForItemExistence(at: folderCiphertextPath) {
			throw CloudProviderError.itemAlreadyExists
		}
	}

	func prepareFolderCreation(dirIdFileURL: URL, preparedFileURL: URL, in decorator: VaultFormat6ProviderDecorator) async throws {}

	/// A file and a folder of the same name have different ciphertext names, so the folder creation checks that no file holds the name.
	func checkFolderCreationTarget(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultFormat6ProviderDecorator) async throws {
		let fileCiphertextPath = try fileCiphertextPath(cleartextPath, parentDirId: parentDirId, in: decorator)
		try Task.checkCancellation()
		if try await decorator.delegate.checkForItemExistence(at: fileCiphertextPath) {
			throw CloudProviderError.itemAlreadyExists
		}
	}

	func createReference(at referencePath: CloudPath, dirIdFileURL: URL, in decorator: VaultFormat6ProviderDecorator) async throws {
		_ = try await decorator.delegate.uploadFile(from: dirIdFileURL, to: referencePath, replaceExisting: false)
	}

	func didCreateDirectory(at dirPath: CloudPath, preparedFileURL: URL, in decorator: VaultFormat6ProviderDecorator) async throws {}

	func isMissingDirFile(_ error: Error) -> Bool {
		return false
	}

	func checkReferenceBeforeDelete(at referencePath: CloudPath, dirId: Data?, in decorator: VaultFormat6ProviderDecorator) async throws {}

	func deleteReference(at referencePath: CloudPath, in decorator: VaultFormat6ProviderDecorator) async throws {
		try await decorator.delegate.deleteFile(at: referencePath)
	}

	func moveReference(from sourceReferencePath: CloudPath, to targetReferencePath: CloudPath, in decorator: VaultFormat6ProviderDecorator) async throws {
		try await decorator.delegate.moveFile(from: sourceReferencePath, to: targetReferencePath)
	}

	func ciphertextItem(named ciphertextName: String, itemType: CloudItemType) -> (baseName: String, itemType: CloudItemType) {
		return parseVaultFormat6CiphertextName(ciphertextName)
	}

	func hasCleartextSize(_ itemType: CloudItemType) -> Bool {
		return itemType == .file || itemType == .symlink
	}

	func subdirectoryIds(of item: CloudItemMetadata, in decorator: VaultFormat6ProviderDecorator) async throws -> [Data] {
		let originalName: String
		do {
			originalName = try await decorator.shortening?.originalName(ofPhysicalItemAt: item.cloudPath) ?? item.name
		} catch where isInvalidNameFile(error) {
			// The library never addresses such an item. Its directory stays without a reference, as after Desktop's directory delete, whose health check reports it as an orphan.
			return []
		}
		guard parseVaultFormat6CiphertextName(originalName).itemType == .folder else {
			return []
		}
		return try await [decorator.physicalProvider.downloadDirFile(at: item.cloudPath, refusingAlias: true)]
	}
}
