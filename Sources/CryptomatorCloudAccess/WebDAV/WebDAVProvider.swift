//
//  WebDAVProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 29.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import Promises

public enum WebDAVProviderError: Error {
	case resolvingURLFailed
	case invalidResponse
}

extension CloudItemMetadata {
	init(_ propfindResponseElement: PropfindResponseElement, cloudPath: CloudPath) {
		self.name = cloudPath.lastPathComponent
		self.cloudPath = cloudPath
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
	private let directoryContentCache: DirectoryContentCache
	private let tmpDirURL: URL

	public init(with client: WebDAVClient, maxPageSize: Int = .max) throws {
		self.client = client
		self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		let dbURL = tmpDirURL.appendingPathComponent("db.sqlite")
		self.directoryContentCache = try DirectoryContentDBCache(dbWriter: DatabaseQueue(path: dbURL.path), maxPageSize: maxPageSize)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
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
			return CloudItemMetadata(firstElement, cloudPath: cloudPath)
		}.recover { error -> Promise<CloudItemMetadata> in
			return self.convertStandardError(error)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let initialPromise: Promise<Void>
		if pageToken != nil {
			initialPromise = Promise(())
		} else {
			initialPromise = updatePropfindResponseCache(forFolderAt: cloudPath)
		}
		return initialPromise.then { _ -> CloudItemList in
			try self.getCachedCloudItemList(forFolderAt: cloudPath, withPageToken: pageToken)
		}.recover { error -> Promise<CloudItemList> in
			return self.convertStandardError(error)
		}
	}

	private func updatePropfindResponseCache(forFolderAt cloudPath: CloudPath) -> Promise<Void> {
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		do {
			try directoryContentCache.clearCache(for: cloudPath)
		} catch {
			return Promise(error)
		}
		let tmpFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		return client.PROPFIND(url: url, depth: .one, to: tmpFileURL, propertyNames: WebDAVProvider.defaultPropertyNames).then { response -> Void in
			let responseURL = response.url ?? url
			guard let inputStream = InputStream(url: tmpFileURL) else {
				throw WebDAVProviderError.invalidResponse
			}
			let parser = CachePropfindResponseParser(XMLParser(stream: inputStream), responseURL: responseURL, cache: self.directoryContentCache, folderEnumerationPath: cloudPath)
			try parser.fillCache()
			inputStream.close()
		}
	}

	private func getCachedCloudItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) throws -> CloudItemList {
		let response = try directoryContentCache.getResponse(for: cloudPath, pageToken: pageToken)
		return CloudItemList(items: response.elements, nextPageToken: response.nextPageToken)
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<Void> {
		precondition(localURL.isFileURL)
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		let progress = Progress(totalUnitCount: 1)
		// GET requests on collections are possible so that it doesn't respond with an error as needed
		// therefore a fetchItemMetadata() is called first to ensure that it's actually a file on remote
		return fetchItemMetadata(at: cloudPath).then { metadata -> Promise<HTTPURLResponse> in
			guard metadata.itemType == .file else {
				throw CloudProviderError.itemTypeMismatch
			}
			progress.becomeCurrent(withPendingUnitCount: 1)
			let getPromise = self.client.GET(from: url, to: localURL, onTaskCreation: onTaskCreation)
			progress.resignCurrent()
			return getPromise
		}.then { _ -> Void in
			// no-op
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

	// swiftlint:disable:next cyclomatic_complexity
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		guard FileManager.default.fileExists(atPath: localURL.path) else {
			return Promise(CloudProviderError.itemNotFound)
		}
		let progress = Progress(totalUnitCount: 1)
		// PUT requests on existing non-collections are possible and there is no way to differentiate it for replaceExisting
		// therefore a fetchItemMetadata() is called first to make that distinction
		return fetchItemMetadata(at: cloudPath).then { metadata -> Void in
			if !replaceExisting || (replaceExisting && metadata.itemType == .folder) {
				throw CloudProviderError.itemAlreadyExists
			}
		}.recover { error -> Void in
			guard case CloudProviderError.itemNotFound = error else {
				throw error
			}
		}.then { _ -> Promise<(HTTPURLResponse, Data?)> in
			progress.becomeCurrent(withPendingUnitCount: 1)
			let putPromise = self.client.PUT(url: url, fileURL: localURL, onTaskCreation: onTaskCreation)
			progress.resignCurrent()
			return putPromise
		}.recover { error -> Promise<(HTTPURLResponse, Data?)> in
			switch error {
			case URLSessionError.httpError(_, statusCode: 401):
				return Promise(CloudProviderError.unauthorized)
			case URLSessionError.httpError(_, statusCode: 405):
				return Promise(CloudProviderError.itemTypeMismatch)
			case URLSessionError.httpError(_, statusCode: 409), URLSessionError.httpError(_, statusCode: 404):
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
		}.then { _, _ -> Promise<CloudItemMetadata> in
			return self.fetchItemMetadata(at: cloudPath)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
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

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath)
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath)
	}

	private func deleteItem(at cloudPath: CloudPath) -> Promise<Void> {
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		return client.DELETE(url: url).then { _, _ -> Void in
			// no-op
		}.recover { error -> Promise<Void> in
			return self.convertStandardError(error)
		}
	}

	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		guard let sourceURL = URL(cloudPath: sourceCloudPath, relativeTo: client.baseURL), let targetURL = URL(cloudPath: targetCloudPath, relativeTo: client.baseURL) else {
			return Promise(WebDAVProviderError.resolvingURLFailed)
		}
		return client.MOVE(sourceURL: sourceURL, destinationURL: targetURL).then { _, _ -> Void in
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

	func convertStandardError<T>(_ error: Error) -> Promise<T> {
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
