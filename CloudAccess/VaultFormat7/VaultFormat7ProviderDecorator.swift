//
//  VaultFormat7ProviderDecorator.swift
//  CloudAccess
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
import CryptomatorCryptoLib

public class VaultFormat7ProviderDecorator: CloudProvider {
	
	let delegate: CloudProvider
	let pathToVault: URL
	let tmpDir: URL
	var cryptor: Cryptor?
	
	public init(delegate: CloudProvider, remotePathToVault: URL) {
		self.delegate = delegate
		self.pathToVault = remotePathToVault
		self.tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
	}
	
	// TODO: declare signature in new protocol "Unlockable" or sth similar
	public func unlock(urlSessionTaskDelegate: URLSessionTaskDelegate, password: String) -> Promise<Void> {
		do {
			try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
		} catch {
			return Promise(error)
		}
		
		// TODO use weakself?
		let localUrl = tmpDir.appendingPathComponent("masterkey.crypomator")
		return delegate.fetchItemMetadata(at: self.pathToVault.appendingPathComponent("masterkey.cryptomator")).then { metadata -> Promise<URLSessionDownloadTask> in
			let cloudFile = CloudFile(localURL: localUrl, metadata: metadata)
			return self.delegate.createBackgroundDownloadTask(for: cloudFile, with: urlSessionTaskDelegate)
		}.then { downloadTask in
			// TODO how the f*** can we wait for this downloadTask to complete?
			throw CloudProviderError.noInternetConnection
		}.then {
			let masterkey = try Masterkey.createFromMasterkeyFile(file: localUrl, password: password)
			self.cryptor = Cryptor(masterKey: masterkey)
		}
	}
	
	public func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func fetchItemList(forFolderAt remoteURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func createBackgroundDownloadTask(for file: CloudFile, with delegate: URLSessionTaskDelegate) -> Promise<URLSessionDownloadTask> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func createBackgroundUploadTask(for file: CloudFile, isUpdate: Bool, with delegate: URLSessionTaskDelegate) -> Promise<URLSessionUploadTask> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func createFolder(at remoteURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func deleteItem(at remoteURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	
	public func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}
	

}
