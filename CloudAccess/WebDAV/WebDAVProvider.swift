//
//  WebDAVProvider.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 29.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

public enum WebDAVProviderError: Error {
	case resolvingURLFailed
	case invalidResponse
}

private extension CloudItemMetadata {
	init(_ propfindResponseElement: PropfindResponseElement, remoteURL: URL) {
		self.name = remoteURL.lastPathComponent
		self.remoteURL = remoteURL
		self.itemType = propfindResponseElement.collection ? .folder : .file
		self.lastModifiedDate = propfindResponseElement.lastModified
		self.size = propfindResponseElement.contentLength
	}
}

/**
 Cloud provider for WebDAV.
 */
public class WebDAVProvider: CloudProvider {
	private static let defaultPropertyNames = ["getlastmodified", "getcontentlength", "resourcetype"]

	private let client: WebDAVClient

	public init(with client: WebDAVClient) {
		self.client = client
	}

	// MARK: - CloudProvider API

	public func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata> {
		precondition(remoteURL.isFileURL)
		guard let url = resolve(remoteURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		return client.PROPFIND(url: url, depth: .zero, propertyNames: WebDAVProvider.defaultPropertyNames).then { response, data -> CloudItemMetadata in
			guard let data = data else {
				throw WebDAVProviderError.invalidResponse
			}
			let parser = PropfindResponseParser(XMLParser(data: data), baseURL: response.url ?? url)
			guard let firstElement = try parser.getElements().first else {
				throw WebDAVProviderError.invalidResponse
			}
			return CloudItemMetadata(firstElement, remoteURL: remoteURL)
		}
	}

	public func fetchItemList(forFolderAt remoteURL: URL, withPageToken _: String?) -> Promise<CloudItemList> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		guard let url = resolve(remoteURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		return client.PROPFIND(url: url, depth: .one, propertyNames: WebDAVProvider.defaultPropertyNames).then { response, data -> CloudItemList in
			guard let data = data else {
				throw WebDAVProviderError.invalidResponse
			}
			let parser = PropfindResponseParser(XMLParser(data: data), baseURL: response.url ?? url)
			let childElements = try parser.getElements().filter({ $0.depth == 1 })
			let items = childElements.map { CloudItemMetadata($0, remoteURL: remoteURL.appendingPathComponent($0.href.lastPathComponent)) }
			return CloudItemList(items: items)
		}
	}

	public func downloadFile(from remoteURL: URL, to localURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(localURL.isFileURL)
		precondition(!remoteURL.hasDirectoryPath)
		precondition(!localURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func uploadFile(from localURL: URL, to remoteURL: URL, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(remoteURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		precondition(!remoteURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func createFolder(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		precondition(remoteURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func deleteItem(at remoteURL: URL) -> Promise<Void> {
		precondition(remoteURL.isFileURL)
		return Promise(CloudProviderError.noInternetConnection)
	}

	public func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void> {
		precondition(oldRemoteURL.isFileURL)
		precondition(newRemoteURL.isFileURL)
		precondition(oldRemoteURL.hasDirectoryPath == newRemoteURL.hasDirectoryPath)
		return Promise(CloudProviderError.noInternetConnection)
	}

	// MARK: - Internal

	private func resolve(_ remoteURL: URL) -> URL? {
		guard let percentEncodedPath = remoteURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
			return nil
		}
		return URL(string: percentEncodedPath, relativeTo: client.baseURL)
	}
}
