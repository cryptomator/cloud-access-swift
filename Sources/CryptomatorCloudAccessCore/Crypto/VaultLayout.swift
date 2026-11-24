//
//  VaultLayout.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 20.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation

/// A shortening decorator of a vault format, which a crypto decorator stacks onto.
protocol VaultShorteningDecorator: CloudProvider {
	/// The provider below the shortening decorator, which lists every item, also one whose shortened name can't be restored.
	var delegate: CloudProvider { get }
}

/**
 The ciphertext layout of a vault format: how `VaultProviderDecorator` names, reads and writes the ciphertext items of a cleartext item.

 Every step that differs between formats is a requirement, because generic code calls an extension-only method statically and never reaches a conforming type's own implementation. Each requirement takes the decorator, so that a layout holds no state.
 */
protocol VaultLayout: Sendable {
	associatedtype Shortening: VaultShorteningDecorator

	init()

	/// The encoding of the encrypted names.
	var fileNameEncoding: FileNameEncoding { get }

	/// Reads the dir ID of a folder from its dir file, after the cache missed it or bypassing the cache.
	func readDirId(_ cleartextPath: CloudPath, parentDirId: Data, refusingAlias: Bool, in decorator: VaultProviderDecorator<Self>) async throws -> Data

	func fileCiphertextPath(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>) throws -> CloudPath

	/// The path of the item that refers to a folder's directory.
	func folderReferencePath(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>) throws -> CloudPath

	/// Derives the ciphertext path of the item, checks cancellation and then reads the ciphertext metadata.
	func fetchCiphertextMetadata(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>) async throws -> CloudItemMetadata

	/// Derives the ciphertext path of the file, checks cancellation and then downloads the ciphertext with the given closure.
	func downloadCiphertextFile(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>, using download: (CloudPath) async throws -> CloudItemMetadata) async throws -> CloudItemMetadata

	/// Checks the target of an upload before its content is encrypted.
	func checkUploadTarget(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>) async throws

	/// Writes what a folder creation uploads besides the dir file to the prepared file, before any request.
	func prepareFolderCreation(dirIdFileURL: URL, preparedFileURL: URL, in decorator: VaultProviderDecorator<Self>) async throws

	/// Checks the target of a folder creation before anything is created.
	func checkFolderCreationTarget(_ cleartextPath: CloudPath, parentDirId: Data, in decorator: VaultProviderDecorator<Self>) async throws

	/// Creates the item that refers to a new folder's directory, with the dir file of the given content. It's the first remote change of a folder creation.
	func createReference(at referencePath: CloudPath, dirIdFileURL: URL, in decorator: VaultProviderDecorator<Self>) async throws

	/// Completes a new folder's directory after it was created.
	func didCreateDirectory(at dirPath: CloudPath, preparedFileURL: URL, in decorator: VaultProviderDecorator<Self>) async throws

	/// Whether an error of reading the dir file of a deleted folder means that the folder has none.
	func isMissingDirFile(_ error: Error) -> Bool

	/// Checks the reference of a deleted folder before the delete commits, with the folder's dir ID if its dir file could be read.
	func checkReferenceBeforeDelete(at referencePath: CloudPath, dirId: Data?, in decorator: VaultProviderDecorator<Self>) async throws

	/// Deletes the reference of a deleted folder after its directory.
	func deleteReference(at referencePath: CloudPath, in decorator: VaultProviderDecorator<Self>) async throws

	func moveReference(from sourceReferencePath: CloudPath, to targetReferencePath: CloudPath, in decorator: VaultProviderDecorator<Self>) async throws

	/// Splits a listed ciphertext name into the encrypted name and the item type, given the type that the provider listed.
	func ciphertextItem(named ciphertextName: String, itemType: CloudItemType) throws -> (baseName: String, itemType: CloudItemType)

	/// Whether the ciphertext of an item of the type holds a file header and content, so that its cleartext size is computed.
	func hasCleartextSize(_ itemType: CloudItemType) -> Bool

	/// Returns the dir IDs that an item of a directory refers to, as listed below any shortening decorator. The folder delete never passes an item that the listing marks as an alias.
	func subdirectoryIds(of item: CloudItemMetadata, in decorator: VaultProviderDecorator<Self>) async throws -> [Data]
}
