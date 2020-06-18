//
//  VaultFormat7ShorteningProviderDecorator.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CommonCrypto
import Foundation
import Promises

enum VaultFormat7ShorteningError: Error {
	case unableToInflateFileName
}

private enum DeflatedFileType {
	case regular
	case shortened
	case unknown
}

private struct DeflatedPath {
	let rawURL: URL
	let contentsFileURL: URL
	let dirFileURL: URL
	let nameFileURL: URL
	let inflatedName: String

	init(deflatedURL: URL, inflatedName: String) {
		self.rawURL = deflatedURL
		self.contentsFileURL = deflatedURL.pathExtension == "c9s" ? deflatedURL.appendingPathComponent("contents.c9r") : deflatedURL
		self.dirFileURL = deflatedURL.appendingPathComponent("dir.c9r")
		self.nameFileURL = deflatedURL.appendingPathComponent("name.c9s")
		self.inflatedName = inflatedName
	}
}

public class VaultFormat7ShorteningProviderDecorator: CloudProvider {
	let delegate: CloudProvider
	let vaultURL: URL
	let tmpDirURL: URL

	public init(delegate: CloudProvider, vaultURL: URL) throws {
		self.delegate = delegate
		self.vaultURL = vaultURL
		self.tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at inflatedURL: URL) -> Promise<CloudItemMetadata> {
		precondition(inflatedURL.isFileURL)
		if inflatedURLNeedsShortening(inflatedURL) {
			let deflatedPath = getDeflatedPath(inflatedURL)
			return self.delegate.fetchItemMetadata(at: deflatedPath.rawURL).then { deflatedMetadata in
				return self.getInflatedMetadata(deflatedMetadata)
			}
		} else {
			return delegate.fetchItemMetadata(at: inflatedURL)
		}
	}

	public func fetchItemList(forFolderAt remoteURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		return delegate.fetchItemList(forFolderAt: remoteURL, withPageToken: pageToken).then { list -> Promise<CloudItemList> in
			let inflatedItemPromises = list.items.map { self.getInflatedMetadata($0) }
			return any(inflatedItemPromises).then { maybeInflatedItems -> CloudItemList in
				let inflatedItems = maybeInflatedItems.filter { $0.value != nil }.map { $0.value! }
				return CloudItemList(items: inflatedItems, nextPageToken: list.nextPageToken)
			}
		}
	}

	public func downloadFile(from remoteURL: URL, to localURL: URL, progress: Progress?) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(localURL.isFileURL)
		precondition(!remoteURL.hasDirectoryPath)
		precondition(!localURL.hasDirectoryPath)
		if deflatedNameIsShortened(deflatedPath.rawURL.lastPathComponent) {

		} else {

		}
		let deflatedPath = getDeflatedPath(remoteURL)
		return delegate.downloadFile(from: deflatedPath.contentsFileURL, to: localURL, progress: progress)
	}

	public func uploadFile(from localURL: URL, to remoteURL: URL, replaceExisting: Bool, progress: Progress?) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(remoteURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		precondition(!remoteURL.hasDirectoryPath)
		let deflatedPath = getDeflatedPath(remoteURL)
		if deflatedNameIsShortened(deflatedPath.rawURL.lastPathComponent) {
			return createC9SFolderAndUploadNameFile(deflatedPath: deflatedPath).then {
				return self.delegate.uploadFile(from: localURL, to: deflatedPath.contentsFileURL, replaceExisting: replaceExisting, progress: progress)
			}.then { deflatedMetadata in
				return self.getInflatedMetadata(deflatedMetadata)
			}
		} else {
			return delegate.uploadFile(from: localURL, to: remoteURL, replaceExisting: replaceExisting, progress: progress)
		}
	}

	public func createFolder(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		let deflatedPath = getDeflatedPath(remoteURL)
		if deflatedNameIsShortened(deflatedPath.rawURL.lastPathComponent) {
			return createC9SFolderAndUploadNameFile(deflatedPath: deflatedPath)
		} else {
			return delegate.createFolder(at: remoteURL)
		}

//		let dirId = UUID().uuidString.data(using: .utf8)!
//		let localDirFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
//		do {
//			try dirId.write(to: localDirFileURL)
//		} catch {
//			return Promise(error)
//		}
//		let c9rPathPromise = getCiphertextPath(cleartextURL)
//		let createFolderAtC9RPathPromise = cleartextNameExceedsMaxLength(cleartextURL.lastPathComponent)
//			? createC9SFolderAndUploadNameFile(c9rPathPromise: c9rPathPromise, cleartextURL: cleartextURL)
//			: c9rPathPromise.then { self.delegate.createFolder(at: $0.rawURL) }.then { c9rPathPromise }
//		return createFolderAtC9RPathPromise.then { c9rPath in
//			return self.delegate.uploadFile(from: localDirFileURL, to: c9rPath.dirFileURL, replaceExisting: false, progress: nil)
//		}.then { _ -> Promise<Void> in
//			let parentDirURL = try self.getDirURL(dirId).deletingLastPathComponent()
//			return self.delegate.createFolder(at: parentDirURL)
//		}.recover { error -> Promise<Void> in
//			if case CloudProviderError.itemAlreadyExists = error {
//				return Promise(())
//			} else {
//				return Promise(error)
//			}
//		}.then { () -> Promise<Void> in
//			let dirURL = try self.getDirURL(dirId)
//			return self.delegate.createFolder(at: dirURL)
//		}.always {
//			try? FileManager.default.removeItem(at: localDirFileURL)
//		}
	}

	public func deleteItem(at cleartextURL: URL) -> Promise<Void> {
		precondition(cleartextURL.isFileURL)
		if cleartextURL.hasDirectoryPath {
			// TODO: recover from error if `getDirId()` rejects with `CloudProviderError.itemNotFound` and delete item anyway (because it's probably a symlink)
			return getDirId(cleartextURL).then { dirId in
				return self.deleteCiphertextDir(dirId)
			}.then {
				return self.getCiphertextPath(cleartextURL)
			}.then { c9rPath in
				return self.delegate.deleteItem(at: c9rPath.rawURL)
			}
		} else {
			return getC9RPath(cleartextURL).then { c9rPath in
				return self.delegate.deleteItem(at: c9rPath.rawURL)
			}
		}
	}

	public func moveItem(from oldCleartextURL: URL, to newCleartextURL: URL) -> Promise<Void> {
		precondition(oldCleartextURL.isFileURL)
		precondition(newCleartextURL.isFileURL)
		precondition(oldCleartextURL.hasDirectoryPath == newCleartextURL.hasDirectoryPath)
		// TODO: shortening
		return all(
			getC9RPath(oldCleartextURL),
			getC9RPath(newCleartextURL)
		).then { oldC9RPath, newC9RPath in
			return self.delegate.moveItem(from: oldC9RPath.rawURL, to: newC9RPath.rawURL)
		}
	}

	// MARK: - Inflation

	private func getInflatedMetadata(_ deflatedMetadata: CloudItemMetadata) -> Promise<CloudItemMetadata> {
		if deflatedNameIsShortened(deflatedMetadata.name) {
			let inflatedNamePromise = inflateFileName(deflatedMetadata.remoteURL)
			let inflatedMetadataPromise = fetchMetadataForC9SContent(deflatedURL: deflatedMetadata.remoteURL)
			return all(inflatedNamePromise, inflatedMetadataPromise).then { inflatedName, inflatedMetadata -> CloudItemMetadata in
				let inflatedURL = deflatedMetadata.remoteURL.deletingLastPathComponent().appendingPathComponent(inflatedName)
				let inflatedItemType = self.guessItemTypeByInflatedName(inflatedMetadata.name)
				return CloudItemMetadata(name: inflatedName, remoteURL: inflatedURL, itemType: inflatedItemType, lastModifiedDate: inflatedMetadata.lastModifiedDate, size: inflatedMetadata.size)
			}
		} else {
			return Promise(deflatedMetadata)
		}
	}

	private func inflateFileName(_ deflatedURL: URL) -> Promise<String> {
		assert(deflatedURL.hasDirectoryPath)
		assert(deflatedURL.pathExtension == "c9s")
		let nameFileURL = deflatedURL.appendingPathComponent("name.c9s")
		return downloadFile(at: nameFileURL).then { data -> String in
			guard let inflatedName = String(data: data, encoding: .utf8) else {
				throw VaultFormat7ShorteningError.unableToInflateFileName
			}
			return inflatedName
		}
	}

	private func fetchMetadataForC9SContent(deflatedURL: URL) -> Promise<CloudItemMetadata> {
		return delegate.fetchItemList(forFolderAt: deflatedURL, withPageToken: nil).then { itemList -> CloudItemMetadata in
			for item in itemList.items {
				switch item.name {
				case "contents.c9r":
					return item
				case "dir.c9r":
					return item
				default:
					continue
				}
			}
			throw VaultFormat7ShorteningError.unableToInflateFileName
		}
	}

	private func guessItemTypeByInflatedName(_ inflatedName: String) -> CloudItemType {
		switch inflatedName {
		case "contents.c9r":
			return .file
		case "dir.c9r":
			return .folder
		default:
			return .unknown
		}
	}

	// MARK: - Deflation

	private func nameExceedsMaxLength(_ ciphertextName: String) -> Bool {
		return ciphertextName.count > 220
	}

	private func deflateFileName(_ inflatedName: String) -> String {
		assert(nameExceedsMaxLength(inflatedName))
		let bytes = [UInt8](inflatedName.precomposedStringWithCanonicalMapping.utf8)
		var digest = [UInt8](repeating: 0x00, count: Int(CC_SHA1_DIGEST_LENGTH))
		CC_SHA1(bytes, UInt32(bytes.count) as CC_LONG, &digest)
		return Data(digest).base64UrlEncodedString()
	}


	private func deflatedNameIsShortened(_ deflatedName: String) -> Bool {
		return String(deflatedName.suffix(4)) == ".c9s"
	}

	private func inflatedURLNeedsShortening(_ inflatedURL: URL) -> Bool {
		// TODO: out of bounds, lol
		return inflatedURL.pathComponents[vaultURL.pathComponents.count + 4].count > 220
	}

	private func getDeflatedPath(_ inflatedURL: URL) -> DeflatedPath {
		let n = vaultURL.pathComponents.count
		let m = vaultURL.pathComponents.count + 4
		let inflatedName = inflatedURL.pathComponents[m]
		assert(String(inflatedName.suffix(4)) == ".c9r")
		let inflatedBaseName = String(inflatedName.prefix(inflatedName.count - 4))
		let deflatedName = { () -> String in
			if nameExceedsMaxLength(inflatedBaseName) {
				return "\(deflateFileName(inflatedBaseName)).c9s"
			} else {
				return "\(inflatedBaseName).c9r"
			}
		}()
		let isDirectory = deflatedNameIsShortened(deflatedName) ? true : inflatedURL.hasDirectoryPath
		var foo = inflatedURL.pathComponents[n...]
		foo[4] = deflatedName
		let bar = foo.reduce(vaultURL, { $0.appendingPathComponent($1) })
		let deflatedURL = inflatedURL.deletingLastPathComponent().appendingPathComponent(deflatedName, isDirectory: isDirectory)
		return DeflatedPath(deflatedURL: deflatedURL, inflatedName: inflatedName)
	}

	// MARK: - Convenience

	// TODO: refactor
	private func downloadFile(at remoteURL: URL) -> Promise<Data> {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		return delegate.downloadFile(from: remoteURL, to: localURL, progress: nil).then {
			return try Data(contentsOf: localURL)
		}.always {
			try? FileManager.default.removeItem(at: localURL)
		}
	}

	private func createC9SFolderAndUploadNameFile(deflatedPath: DeflatedPath) -> Promise<Void> {
		return delegate.createFolder(at: deflatedPath.rawURL).then { _ -> Promise<CloudItemMetadata> in
			let localNameFileURL = self.tmpDirURL.appendingPathComponent(UUID().uuidString)
			try deflatedPath.inflatedName.write(to: localNameFileURL, atomically: true, encoding: .utf8)
			return self.delegate.uploadFile(from: localNameFileURL, to: deflatedPath.nameFileURL, replaceExisting: false, progress: nil)
		}.then { _ in () }
	}
}
