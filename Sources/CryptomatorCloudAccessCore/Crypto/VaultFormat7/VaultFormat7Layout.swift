//
//  VaultFormat7Layout.swift
//  CryptomatorCloudAccess
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation

/// Cloud provider decorator for Cryptomator vaults in vault format 7 (without name shortening). To be fully compatible with vault format 7, stack it onto a `VaultFormat7ShorteningProviderDecorator`.
typealias VaultFormat7ProviderDecorator = VaultProviderDecorator<VaultFormat7Layout>

private extension CloudPath {
	func appendingDirFileComponent() -> CloudPath {
		return appendingPathComponent("dir.c9r")
	}
}

/// Whether a listed item of a `.c9r` or `.c9s` is the file that holds its dir ID. A folder of that name holds none.
private func isDirFile(_ item: CloudItemMetadata) -> Bool {
	return item.name == "dir.c9r" && item.itemType == .file
}

/**
 The ciphertext layout of vault formats 7 and 8, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.5/security/architecture/): Base64url names with a `.c9r` extension, and a folder's dir ID in the `dir.c9r` file of a `.c9r` folder.

 A folder delete lists the directories below the shortening decorator and follows every `dir.c9r` file of a `.c9r` or `.c9s` folder without reading its name. A subfolder whose `name.c9s` is invalid or can't be read is therefore deleted with its parent, rather than leaving its directory without a reference. It skips a `dir.c9r` that the listing marks as an alias. If a download reaches a `dir.c9r` through an alias, it fails the `.c9r` or `.c9s` item, which then stays.
 */
protocol C9RVaultLayout: VaultLayout where Shortening == VaultFormat7ShorteningProviderDecorator {}

extension C9RVaultLayout {
	var fileNameEncoding: FileNameEncoding {
		return .base64url
	}

	func readDirId(_ cleartextPath: CloudPath, parentDirId: Data, refusingAlias: Bool, in decorator: VaultProviderDecorator<Self>) async throws -> Data {
		let c9rPath = try folderReferencePath(cleartextPath, parentDirId: parentDirId, in: decorator)
		do {
			return try await decorator.delegate.downloadDirFile(at: c9rPath.appendingDirFileComponent(), refusingAlias: refusingAlias)
		} catch CloudProviderError.itemNotFound {
			try Task.checkCancellation()
			if try await decorator.delegate.checkForItemExistence(at: c9rPath) {
				// `*.c9r` exists but `*.c9r/dir.c9r` does not, so it's not a directory as expected
				throw CloudProviderError.itemTypeMismatch
			} else {
				throw CloudProviderError.itemNotFound
			}
		}
	}

	func fileCiphertextPath(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>) throws -> CloudPath {
		let ciphertextBaseName = try decorator.ciphertextName(of: cleartextPath, parentDirId: parentDirId)
		return try decorator.dirPath(of: parentDirId).appendingPathComponent("\(ciphertextBaseName).c9r")
	}

	func folderReferencePath(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>) throws -> CloudPath {
		return try fileCiphertextPath(cleartextPath, parentDirId: parentDirId, in: decorator)
	}

	func fetchCiphertextMetadata(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>) async throws -> CloudItemMetadata {
		let c9rPath = try fileCiphertextPath(cleartextPath, parentDirId: parentDirId, in: decorator)
		try Task.checkCancellation()
		return try await decorator.delegate.fetchItemMetadata(at: c9rPath)
	}

	func downloadCiphertextFile(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>, using download: (CloudPath) async throws -> CloudItemMetadata) async throws -> CloudItemMetadata {
		let c9rPath = try fileCiphertextPath(cleartextPath, parentDirId: parentDirId, in: decorator)
		try Task.checkCancellation()
		return try await download(c9rPath)
	}

	func checkUploadTarget(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>) async throws {}

	func prepareFolderCreation(dirIdFileURL: URL, preparedFileURL: URL, in decorator: VaultProviderDecorator<Self>) async throws {}

	func checkFolderCreationTarget(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>) async throws {}

	func createReference(at referencePath: CloudPath, dirIdFileURL: URL, in decorator: VaultProviderDecorator<Self>) async throws {
		try await decorator.delegate.createFolder(at: referencePath)
		_ = try await decorator.delegate.uploadFile(from: dirIdFileURL, to: referencePath.appendingDirFileComponent(), replaceExisting: false)
	}

	func didCreateDirectory(at dirPath: CloudPath, preparedFileURL: URL, in decorator: VaultProviderDecorator<Self>) async throws {}

	/// `itemTypeMismatch`: the `.c9r` exists, but the download found no `dir.c9r`, e.g., it's a symlink. `itemNotFound`: the `.c9r` is gone, or it's a `.c9s` that the shortening decorator reports as missing because it holds no item file. Either way it's deleted without a walk unless it lists a `dir.c9r`.
	func isMissingDirFile(_ error: Error) -> Bool {
		switch error {
		case CloudProviderError.itemNotFound, CloudProviderError.itemTypeMismatch:
			return true
		default:
			return false
		}
	}

	func checkReferenceBeforeDelete(at referencePath: CloudPath, dirId: Data?, in decorator: VaultProviderDecorator<Self>) async throws {
		let holdsUnreadableDirFile = dirId == nil ? try await holdsDirFile(referencePath, in: decorator) : false
		try Task.checkCancellation()
		if holdsUnreadableDirFile {
			// A provider that addresses items by cached IDs reports a `dir.c9r` that another client replaced as missing. Deleting the `.c9r` would orphan its directory. A later delete can read the new ID once the provider has cached it, which some providers' listings do.
			throw CloudProviderError.itemNotFound
		}
	}

	func deleteReference(at referencePath: CloudPath, in decorator: VaultProviderDecorator<Self>) async throws {
		try await decorator.delegate.deleteFolder(at: referencePath)
	}

	func moveReference(from sourceReferencePath: CloudPath, to targetReferencePath: CloudPath, in decorator: VaultProviderDecorator<Self>) async throws {
		try await decorator.delegate.moveFolder(from: sourceReferencePath, to: targetReferencePath)
	}

	func ciphertextItem(named ciphertextName: String, itemType: CloudItemType) throws -> (baseName: String, itemType: CloudItemType) {
		guard let ciphertextBaseName = ciphertextName.removingUTF8Suffix(".c9r") else {
			throw VaultFormatError.encounteredUnrelatedFile
		}
		return (ciphertextBaseName, itemType)
	}

	func hasCleartextSize(_ itemType: CloudItemType) -> Bool {
		return itemType == .file
	}

	func subdirectoryIds(of item: CloudItemMetadata, in decorator: VaultProviderDecorator<Self>) async throws -> [Data] {
		guard item.itemType == .folder, item.name.removingUTF8Suffix(".c9r") != nil || item.name.removingUTF8Suffix(".c9s") != nil else {
			return []
		}
		var dirIds = [Data]()
		for dirFile in try await decorator.physicalProvider.fetchItemListExhaustively(forFolderAt: item.cloudPath).items where isDirFile(dirFile) && !dirFile.isAlias {
			try await dirIds.append(decorator.physicalProvider.downloadDirFile(at: dirFile.cloudPath, refusingAlias: true))
		}
		return dirIds
	}

	/// Whether the folder of a `.c9r` or `.c9s` holds a `dir.c9r` file, as listed below the shortening decorator. A first page that throws `itemNotFound` or `itemTypeMismatch` means none. Any other failure is thrown, because the pages not listed yet may hold it. A `dir.c9r` that the listing marks as an alias counts too, because keeping a `.c9r` whose dir ID can't be read is the safe side.
	private func holdsDirFile(_ c9rPath: CloudPath, in decorator: VaultProviderDecorator<Self>) async throws -> Bool {
		let containerPath = decorator.shortening?.shortenedNameCache.getShortenedPath(c9rPath).cloudPath ?? c9rPath
		var pageToken: String?
		repeat {
			try Task.checkCancellation()
			let itemList: CloudItemList
			do {
				itemList = try await decorator.physicalProvider.fetchItemList(forFolderAt: containerPath, withPageToken: pageToken)
			} catch let error as CloudProviderError where pageToken == nil && [.itemNotFound, .itemTypeMismatch].contains(error) {
				return false
			}
			if itemList.items.contains(where: isDirFile) {
				return true
			}
			pageToken = itemList.nextPageToken
		} while pageToken != nil
		return false
	}
}

struct VaultFormat7Layout: C9RVaultLayout {}
