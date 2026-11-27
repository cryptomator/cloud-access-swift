//
//  VaultFormat7Layout.swift
//  CryptomatorCloudAccessCore
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

	func appendingContentsFileComponent() -> CloudPath {
		return appendingPathComponent("contents.c9r")
	}
}

/// Whether a listed item of a `.c9r` or `.c9s` is the file that holds its dir ID. A folder of that name holds none.
private func isDirFile(_ item: CloudItemMetadata) -> Bool {
	return item.name == "dir.c9r" && item.itemType == .file
}

/// Whether a listed item of a `.c9s` is the file that holds a shortened file's content.
private func isContentsFile(_ item: CloudItemMetadata) -> Bool {
	return item.name == "contents.c9r" && item.itemType == .file
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

	/// A shortened file is a `.c9s` folder, whose type the shortening decorator takes from the first item file it lists, so its file is confirmed from the physical `.c9s` instead.
	func readDirId(_ cleartextPath: CloudPath, parentDirId: Data, refusingAlias: Bool, in decorator: VaultProviderDecorator<Self>) async throws -> DirIdReadResult {
		let c9rPath = try folderReferencePath(cleartextPath, parentDirId: parentDirId, in: decorator)
		do {
			return try await .directory(decorator.delegate.downloadDirFile(at: c9rPath.appendingDirFileComponent(), refusingAlias: refusingAlias))
		} catch CloudProviderError.itemNotFound {
			try Task.checkCancellation()
			if case let .c9sDirectory(c9sDir) = decorator.shortening?.shortenedNameCache.getShortenedPath(c9rPath) {
				return try await confirmFile(inC9S: c9sDir.cloudPath, in: decorator)
			}
			return try await decorator.physicalProvider.confirmFile(at: c9rPath)
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

	/// `itemTypeMismatch`: the `.c9r` or `.c9s` exists and is no confirmed file, but the download found no `dir.c9r`, e.g., it's a symlink or a stale cached ID reaches it. `itemNotFound`: the `.c9r` or `.c9s` is gone, or it's a `.c9s` that is a file or holds no item file. Either way it's deleted without a walk unless it lists a `dir.c9r`, or it's a `.c9s` that holds a `contents.c9r` file. A confirmed file is no error, so it never gets here.
	func isMissingDirFile(_ error: Error) -> Bool {
		switch error {
		case CloudProviderError.itemNotFound, CloudProviderError.itemTypeMismatch:
			return true
		default:
			return false
		}
	}

	func checkReferenceBeforeDelete(at referencePath: CloudPath, dirId: Data?, in decorator: VaultProviderDecorator<Self>) async throws {
		guard dirId == nil else {
			return
		}
		let holdsUnreadableDirFile = try await holdsDirFile(referencePath, in: decorator)
		try Task.checkCancellation()
		if holdsUnreadableDirFile {
			// A provider that addresses items by cached IDs reports a `dir.c9r` that another client replaced as missing. Deleting the `.c9r` would orphan its directory. A later delete can read the new ID once the provider has cached it, which some providers' listings do.
			throw CloudProviderError.itemNotFound
		}
		let holdsContentsFile = try await holdsContentsFile(referencePath, in: decorator)
		try Task.checkCancellation()
		if holdsContentsFile {
			// A shortened file that couldn't be confirmed, e.g., because a stale cached ID reaches its `.c9s` after another client renamed it. Deleting the `.c9s` as a folder would delete the file.
			throw CloudProviderError.itemTypeMismatch
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
		guard item.itemType == .folder, item.name.hasUTF8Suffix(".c9r") || item.name.hasUTF8Suffix(".c9s") else {
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

	/// Whether the `.c9s` of a shortened name holds a `contents.c9r` file. It's read by its path below the shortening decorator, because a listing can leave it out (LocalFS skips a hidden one) or fail before reaching it. Any failure but `itemNotFound` is thrown. A `contents.c9r` in a plain `.c9r` holds no file, so it isn't looked up.
	private func holdsContentsFile(_ c9rPath: CloudPath, in decorator: VaultProviderDecorator<Self>) async throws -> Bool {
		guard case let .c9sDirectory(c9sDir) = decorator.shortening?.shortenedNameCache.getShortenedPath(c9rPath) else {
			return false
		}
		do {
			return try await decorator.physicalProvider.fetchItemMetadata(at: c9sDir.cloudPath.appendingContentsFileComponent()).itemType == .file
		} catch CloudProviderError.itemNotFound {
			return false
		}
	}

	/**
	 Tells from the physical `.c9s` of a name without a readable `dir.c9r` whether a regular file holds the name. Only a complete listing whose item files are all `contents.c9r` files, at least one, confirms it, because the item files of a `.c9s` can lie on any page. A listed `dir.c9r` file settles that it's no file at once. Its own metadata need only report its name: S3 reports an object at the `.c9s` key as a file even while the `.c9s` prefix holds items.

	 - Throws: `CloudProviderError.itemNotFound` if the `.c9s` is gone, if its first page throws `itemNotFound` or `itemTypeMismatch` (e.g., because the `.c9s` is a file), or if it holds no item file, as the shortening decorator reports it. `CloudProviderError.itemTypeMismatch` if it reports another name, e.g., a renamed `.c9s` that a stale cached ID reaches, or if it lists another item file than a `contents.c9r` file. A later page that throws either error also yields `itemTypeMismatch`, because the pages listed so far can't tell. Any other failure is thrown unchanged.
	 */
	private func confirmFile(inC9S c9sPath: CloudPath, in decorator: VaultProviderDecorator<Self>) async throws -> DirIdReadResult {
		let metadata = try await decorator.physicalProvider.fetchItemMetadata(at: c9sPath)
		guard metadata.reportsName(of: c9sPath) else {
			throw CloudProviderError.itemTypeMismatch
		}
		var holdsContentsFile = false
		var holdsOtherItemFile = false
		var pageToken: String?
		repeat {
			try Task.checkCancellation()
			let itemList: CloudItemList
			do {
				itemList = try await decorator.physicalProvider.fetchItemList(forFolderAt: c9sPath, withPageToken: pageToken)
			} catch let error as CloudProviderError where [.itemNotFound, .itemTypeMismatch].contains(error) {
				throw pageToken == nil ? CloudProviderError.itemNotFound : CloudProviderError.itemTypeMismatch
			}
			if itemList.items.contains(where: isDirFile) {
				throw CloudProviderError.itemTypeMismatch
			}
			let itemFiles = itemList.items.filter { guessItemTypeByC9SItemName($0.name) != .unknown }
			holdsContentsFile = holdsContentsFile || itemFiles.contains(where: isContentsFile)
			holdsOtherItemFile = holdsOtherItemFile || !itemFiles.allSatisfy(isContentsFile)
			pageToken = itemList.nextPageToken
		} while pageToken != nil
		if holdsOtherItemFile {
			throw CloudProviderError.itemTypeMismatch
		}
		guard holdsContentsFile else {
			throw CloudProviderError.itemNotFound
		}
		return .confirmedFile
	}
}

struct VaultFormat7Layout: C9RVaultLayout {}
