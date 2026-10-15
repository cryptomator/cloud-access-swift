//
//  WebDAVProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 29.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

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
public final class WebDAVProvider: CloudProvider {
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

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		return try await getItemMetadata(at: cloudPath)
	}

	/// Doesn't check for cancellation, so that an upload can still fetch the metadata to return after its remote change.
	private func getItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		do {
			let (response, data) = try await client.PROPFIND(url: url, depth: .zero, propertyNames: WebDAVProvider.defaultPropertyNames)
			guard let data else {
				throw WebDAVProviderError.invalidResponse
			}
			let parser = PropfindResponseParser(XMLParser(data: data), responseURL: response.url ?? url)
			guard let firstElement = try parser.getElements().first else {
				throw WebDAVProviderError.invalidResponse
			}
			return CloudItemMetadata(firstElement, cloudPath: cloudPath)
		} catch URLSessionError.httpError(_, statusCode: 405) {
			// Workaround for: https://github.com/nextcloud/server/issues/34574
			throw CloudProviderError.itemNotFound
		} catch {
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		do {
			if pageToken == nil {
				try await updatePropfindResponseCache(forFolderAt: cloudPath)
			}
			return try getCachedCloudItemList(forFolderAt: cloudPath, withPageToken: pageToken)
		} catch URLSessionError.httpError(_, statusCode: 405) {
			// Workaround for: https://github.com/nextcloud/server/issues/34574
			throw CloudProviderError.itemNotFound
		} catch {
			throw convertStandardError(error)
		}
	}

	private func updatePropfindResponseCache(forFolderAt cloudPath: CloudPath) async throws {
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		try directoryContentCache.clearCache(for: cloudPath)
		let tmpFileURL = tmpDirURL.appendingPathComponent(UUID().uuidString)
		defer {
			try? FileManager.default.removeItem(at: tmpFileURL)
		}
		let response = try await client.PROPFIND(url: url, depth: .one, to: tmpFileURL, propertyNames: WebDAVProvider.defaultPropertyNames)
		try Task.checkCancellation()
		let responseURL = response.url ?? url
		guard let inputStream = InputStream(url: tmpFileURL) else {
			throw WebDAVProviderError.invalidResponse
		}
		let parser = CachePropfindResponseParser(XMLParser(stream: inputStream), responseURL: responseURL, cache: directoryContentCache, folderEnumerationPath: cloudPath)
		try parser.fillCache()
		inputStream.close()
	}

	private func getCachedCloudItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) throws -> CloudItemList {
		let response = try directoryContentCache.getResponse(for: cloudPath, pageToken: pageToken)
		return CloudItemList(items: response.elements, nextPageToken: response.nextPageToken)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		let phases = Progress.phases(of: progress, 999)
		do {
			// A GET request on a collection doesn't fail, so the metadata is fetched first to ensure that the item is a file.
			let remoteMetadata = try await getItemMetadata(at: cloudPath)
			guard remoteMetadata.itemType == .file else {
				throw CloudProviderError.itemTypeMismatch
			}
			try Task.checkCancellation()
			let metadata = try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
				_ = try await client.GET(from: url, to: stagedFile, progress: phases[0], onTaskCreation: onTaskCreation)
				return remoteMetadata
			})
			phases.completeTransfer()
			return metadata
		} catch {
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		var isDirectory: ObjCBool = false
		let fileExists = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
		if !fileExists {
			throw CloudProviderError.itemNotFound
		}
		if isDirectory.boolValue {
			throw CloudProviderError.itemTypeMismatch
		}
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		let phases = Progress.phases(of: progress, 999)
		do {
			// A PUT request on an existing file succeeds regardless of `replaceExisting`, so the metadata is fetched first to make that distinction.
			do {
				let metadata = try await getItemMetadata(at: cloudPath)
				if !replaceExisting || (replaceExisting && metadata.itemType == .folder) {
					throw CloudProviderError.itemAlreadyExists
				}
			} catch CloudProviderError.itemNotFound {
				// no-op
			}
			try Task.checkCancellation()
			_ = try await client.PUT(url: url, fileURL: localURL, progress: phases[0], onTaskCreation: onTaskCreation)
		} catch {
			switch error {
			case URLSessionError.httpError(_, statusCode: 409), URLSessionError.httpError(_, statusCode: 404):
				throw CloudProviderError.parentFolderDoesNotExist
			case URLSessionError.httpError(_, statusCode: 507):
				throw CloudProviderError.quotaInsufficient
			default:
				throw convertStandardError(error)
			}
		}
		let metadata = try await getItemMetadata(at: cloudPath)
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		do {
			_ = try await client.MKCOL(url: url)
		} catch {
			switch error {
			case URLSessionError.httpError(_, statusCode: 401), URLSessionError.httpError(_, statusCode: 403):
				throw CloudProviderError.unauthorized
			case URLSessionError.httpError(_, statusCode: 405):
				throw CloudProviderError.itemAlreadyExists
			case URLSessionError.httpError(_, statusCode: 409):
				throw CloudProviderError.parentFolderDoesNotExist
			case URLSessionError.httpError(_, statusCode: 507):
				throw CloudProviderError.quotaInsufficient
			default:
				if isNetworkConnectionError(error) {
					throw CloudProviderError.noInternetConnection
				}
				throw error
			}
		}
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await deleteItem(at: cloudPath)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await deleteItem(at: cloudPath)
	}

	private func deleteItem(at cloudPath: CloudPath) async throws {
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		do {
			_ = try await client.DELETE(url: url)
		} catch {
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		guard let sourceURL = URL(cloudPath: sourceCloudPath, relativeTo: client.baseURL), let targetURL = URL(cloudPath: targetCloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		do {
			_ = try await client.MOVE(sourceURL: sourceURL, destinationURL: targetURL)
		} catch {
			switch error {
			case URLSessionError.httpError(_, statusCode: 401), URLSessionError.httpError(_, statusCode: 403):
				throw CloudProviderError.unauthorized
			case URLSessionError.httpError(_, statusCode: 404):
				throw CloudProviderError.itemNotFound
			case URLSessionError.httpError(_, statusCode: 409):
				throw CloudProviderError.parentFolderDoesNotExist
			case URLSessionError.httpError(_, statusCode: 412):
				throw CloudProviderError.itemAlreadyExists
			case URLSessionError.httpError(_, statusCode: 507):
				throw CloudProviderError.quotaInsufficient
			default:
				if isNetworkConnectionError(error) {
					throw CloudProviderError.noInternetConnection
				}
				throw error
			}
		}
	}

	func convertStandardError(_ error: Error) -> Error {
		switch error {
		case URLSessionError.httpError(_, statusCode: 401), URLSessionError.httpError(_, statusCode: 403):
			return CloudProviderError.unauthorized
		case URLSessionError.httpError(_, statusCode: 404):
			return CloudProviderError.itemNotFound
		default:
			if isNetworkConnectionError(error) {
				return CloudProviderError.noInternetConnection
			}
			return error
		}
	}
}
