//
//  WebDAVProvider.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 29.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

/**
 Cloud provider for WebDAV.
 */
public class WebDAVProvider: CloudProvider {
	private let client: WebDAVClient

	public init(with client: WebDAVClient) {
		self.client = client
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func fetchItemList(forFolderAt remoteURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func downloadFile(from remoteURL: URL, to localURL: URL) -> Promise<Void> {
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func uploadFile(from localURL: URL, to remoteURL: URL, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
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
