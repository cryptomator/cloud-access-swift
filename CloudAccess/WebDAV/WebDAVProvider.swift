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
	init(_ propfindResponseElement: PropfindResponseElement, cloudPath: CloudPath) {
		self.name = cloudPath.lastPathComponent
		self.cloudPath = cloudPath
		self.itemType = {
			guard let collection = propfindResponseElement.collection else {
				return .unknown
			}
			return collection ? .folder : .file
		}()
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

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		return client.PROPFIND(url: url, depth: .zero, propertyNames: WebDAVProvider.defaultPropertyNames).then { response, data -> CloudItemMetadata in
			guard let data = data else {
				throw WebDAVProviderError.invalidResponse
			}
			let parser = PropfindResponseParser(XMLParser(data: data), responseURL: response.url ?? url)
			guard let firstElement = try parser.getElements().first else {
				throw WebDAVProviderError.invalidResponse
			}
			let metadata = CloudItemMetadata(firstElement, cloudPath: cloudPath)
			guard self.validateItemType(at: url, with: metadata.itemType) else {
				throw CloudProviderError.itemTypeMismatch
			}
			return metadata
		}.recover { error -> Promise<CloudItemMetadata> in
			switch error {
			case URLSessionError.httpError(_, statusCode: 401):
				return Promise(CloudProviderError.unauthorized)
			case URLSessionError.httpError(_, statusCode: 404):
				return Promise(CloudProviderError.itemNotFound)
			case URLError.notConnectedToInternet:
				return Promise(CloudProviderError.noInternetConnection)
			default:
				return Promise(error)
			}
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken _: String?) -> Promise<CloudItemList> {
		precondition(cloudPath.hasDirectoryPath)
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		return client.PROPFIND(url: url, depth: .one, propertyNames: WebDAVProvider.defaultPropertyNames).then { response, data -> CloudItemList in
			guard let data = data else {
				throw WebDAVProviderError.invalidResponse
			}
			let parser = PropfindResponseParser(XMLParser(data: data), responseURL: response.url ?? url)
			let elements = try parser.getElements()
			guard let rootElement = elements.filter({ $0.depth == 0 }).first else {
				throw WebDAVProviderError.invalidResponse
			}
			let rootMetadata = CloudItemMetadata(rootElement, cloudPath: cloudPath)
			guard rootMetadata.itemType == .folder else {
				throw CloudProviderError.itemTypeMismatch
			}
			let childElements = elements.filter({ $0.depth == 1 })
			let items = childElements.map { CloudItemMetadata($0, cloudPath: cloudPath.appendingPathComponent($0.url.lastPathComponent)) }
			return CloudItemList(items: items)
		}.recover { error -> Promise<CloudItemList> in
			switch error {
			case URLSessionError.httpError(_, statusCode: 401):
				return Promise(CloudProviderError.unauthorized)
			case URLSessionError.httpError(_, statusCode: 404):
				return Promise(CloudProviderError.itemNotFound)
			case URLError.notConnectedToInternet:
				return Promise(CloudProviderError.noInternetConnection)
			default:
				return Promise(error)
			}
		}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		precondition(!cloudPath.hasDirectoryPath)
		precondition(!localURL.hasDirectoryPath)
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		// GET requests on collections are possible so that it doesn't respond with an error as needed
		// therefore a fetchItemMetadata() is called first to ensure that it's actually a file on remote
		// CloudProviderError.itemTypeMismatch is already thrown by fetchItemMetadata() so it doesn't need to be catched
		return fetchItemMetadata(at: cloudPath).then { _ in
			return self.client.GET(url: url)
		}.then { _, fileURL -> Void in
			guard let fileURL = fileURL else {
				throw WebDAVProviderError.invalidResponse
			}
			try FileManager.default.moveItem(at: fileURL, to: localURL)
		}.recover { error -> Promise<Void> in
			switch error {
			case URLSessionError.httpError(_, statusCode: 401):
				return Promise(CloudProviderError.unauthorized)
			case URLSessionError.httpError(_, statusCode: 404):
				return Promise(CloudProviderError.itemNotFound)
			case URLError.notConnectedToInternet:
				return Promise(CloudProviderError.noInternetConnection)
			case CocoaError.fileWriteFileExists:
				return Promise(CloudProviderError.itemAlreadyExists)
			default:
				return Promise(error)
			}
		}
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		precondition(!cloudPath.hasDirectoryPath)
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		guard FileManager.default.fileExists(atPath: localURL.path) else {
			return Promise(CloudProviderError.itemNotFound)
		}
		// PUT requests on existing non-collections are possible and there is no way to differentiate it for replaceExisting
		// therefore a fetchItemMetadata() is called first to make that distinction
		return fetchItemMetadata(at: cloudPath).then { _ in
			if replaceExisting {
				return self.client.PUT(url: url, fileURL: localURL)
			} else {
				return Promise(CloudProviderError.itemAlreadyExists)
			}
		}.recover { error -> Promise<(HTTPURLResponse, Data?)> in
			switch (error, replaceExisting) {
			case (CloudProviderError.itemNotFound, _):
				return self.client.PUT(url: url, fileURL: localURL)
			case (CloudProviderError.itemTypeMismatch, false):
				return Promise(CloudProviderError.itemAlreadyExists)
			default:
				return Promise(error)
			}
		}.then { response, data -> CloudItemMetadata in
			guard let data = data else {
				throw WebDAVProviderError.invalidResponse
			}
			let parser = PropfindResponseParser(XMLParser(data: data), responseURL: response.url ?? url)
			guard let firstElement = try parser.getElements().first else {
				throw WebDAVProviderError.invalidResponse
			}
			return CloudItemMetadata(firstElement, cloudPath: cloudPath)
		}.recover { error -> Promise<CloudItemMetadata> in
			switch error {
			case URLSessionError.httpError(_, statusCode: 401):
				return Promise(CloudProviderError.unauthorized)
			case URLSessionError.httpError(_, statusCode: 405):
				return Promise(CloudProviderError.itemTypeMismatch)
			case URLSessionError.httpError(_, statusCode: 409):
				return Promise(CloudProviderError.parentFolderDoesNotExist)
			case URLSessionError.httpError(_, statusCode: 507):
				return Promise(CloudProviderError.quotaInsufficient)
			case URLError.notConnectedToInternet:
				return Promise(CloudProviderError.noInternetConnection)
			case POSIXError.EISDIR:
				return Promise(CloudProviderError.itemTypeMismatch)
			default:
				return Promise(error)
			}
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		precondition(cloudPath.hasDirectoryPath)
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		return client.MKCOL(url: url).then { _, _ -> Void in
			// no-op
		}.recover { error -> Promise<Void> in
			switch error {
			case URLSessionError.httpError(_, statusCode: 401):
				return Promise(CloudProviderError.unauthorized)
			case URLSessionError.httpError(_, statusCode: 405):
				return Promise(CloudProviderError.itemAlreadyExists)
			case URLSessionError.httpError(_, statusCode: 409):
				return Promise(CloudProviderError.parentFolderDoesNotExist)
			case URLSessionError.httpError(_, statusCode: 507):
				return Promise(CloudProviderError.quotaInsufficient)
			case URLError.notConnectedToInternet:
				return Promise(CloudProviderError.noInternetConnection)
			default:
				return Promise(error)
			}
		}
	}

	public func deleteItem(at cloudPath: CloudPath) -> Promise<Void> {
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		// DELETE requests have no distinction between collections and non-collections
		// therefore a fetchItemMetadata() is called first to ensure that the expected file type matches on remote
		// CloudProviderError.itemTypeMismatch is already thrown by fetchItemMetadata() so it doesn't need to be catched
		return fetchItemMetadata(at: cloudPath).then { _ in
			return self.client.DELETE(url: url)
		}.then { _, _ -> Void in
			// no-op
		}.recover { error -> Promise<Void> in
			switch error {
			case URLSessionError.httpError(_, statusCode: 401):
				return Promise(CloudProviderError.unauthorized)
			case URLSessionError.httpError(_, statusCode: 404):
				return Promise(CloudProviderError.itemNotFound)
			case URLError.notConnectedToInternet:
				return Promise(CloudProviderError.noInternetConnection)
			default:
				return Promise(error)
			}
		}
	}

	public func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		precondition(sourceCloudPath.hasDirectoryPath == targetCloudPath.hasDirectoryPath)
		guard let sourceURL = URL(cloudPath: sourceCloudPath, relativeTo: client.baseURL), let targetURL = URL(cloudPath: targetCloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		// MOVE requests have no distinction between collections and non-collections
		// therefore a fetchItemMetadata() is called first to ensure that the expected file type matches on remote
		// CloudProviderError.itemTypeMismatch is already thrown by fetchItemMetadata() so it doesn't need to be catched
		return fetchItemMetadata(at: sourceCloudPath).then { _ in
			return self.client.MOVE(sourceURL: sourceURL, destinationURL: targetURL)
		}.then { _, _ -> Void in
			// no-op
		}.recover { error -> Promise<Void> in
			switch error {
			case URLSessionError.httpError(_, statusCode: 401):
				return Promise(CloudProviderError.unauthorized)
			case URLSessionError.httpError(_, statusCode: 404):
				return Promise(CloudProviderError.itemNotFound)
			case URLSessionError.httpError(_, statusCode: 409):
				return Promise(CloudProviderError.parentFolderDoesNotExist)
			case URLSessionError.httpError(_, statusCode: 412):
				return Promise(CloudProviderError.itemAlreadyExists)
			case URLSessionError.httpError(_, statusCode: 507):
				return Promise(CloudProviderError.quotaInsufficient)
			case URLError.notConnectedToInternet:
				return Promise(CloudProviderError.noInternetConnection)
			default:
				return Promise(error)
			}
		}
	}

	// MARK: - Internal

	private func validateItemType(at url: URL, with itemType: CloudItemType) -> Bool {
		return url.hasDirectoryPath == (itemType == .folder) || !url.hasDirectoryPath == (itemType == .file)
	}
}
