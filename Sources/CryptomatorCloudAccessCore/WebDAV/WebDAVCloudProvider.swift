//
//  WebDAVCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 29.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

enum WebDAVProviderError: Error {
	case resolvingURLFailed
	/// A PROPFIND response that the provider can't use, including one with a construct or an encoding that `WebDAVXMLGuard` doesn't support (`WebDAVXMLGuardError.unsupported`).
	case invalidResponse
	/// A PROPFIND response exceeds a cap of `WebDAVXMLLimits`: the text of an element or the nesting, which `PropfindResponseParser` enforces, or a cap of `WebDAVXMLGuard`.
	case responseTooLarge
}

extension CloudItemMetadata {
	init(_ propfindResponseElement: PropfindResponseElement, cloudPath: CloudPath) {
		self.init(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: propfindResponseElement.collection ? .folder : .file, lastModifiedDate: propfindResponseElement.lastModified, size: propfindResponseElement.contentLength)
	}
}

/**
 Cloud provider for WebDAV.
 */
public final class WebDAVCloudProvider: CloudProvider {
	private static let defaultPropertyNames = ["getlastmodified", "getcontentlength", "resourcetype"]

	private let client: WebDAVClient
	let directoryContentCache: DirectoryContentCache
	private let tmpDirURL: URL

	public convenience init(credential: WebDAVCredential, maxPageSize: Int = .max) throws {
		try self.init(client: WebDAVClient(credential: credential), maxPageSize: maxPageSize)
	}

	/**
	 Creates a WebDAV provider whose file downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests, including streamed folder listings, run on a foreground URL session.

	 - Parameter sharedContainerIdentifier: The container into which the background URL session downloads files, which an app extension must share with its app, or `nil` in the app.
	 */
	public static func withBackgroundSession(credential: WebDAVCredential, maxPageSize: Int = .max, sessionIdentifier: String, sharedContainerIdentifier: String?) throws -> WebDAVCloudProvider {
		let session = WebDAVSession.createBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
		return try WebDAVCloudProvider(client: WebDAVClient(credential: credential, session: session), maxPageSize: maxPageSize)
	}

	init(client: WebDAVClient, maxPageSize: Int = .max) throws {
		self.client = client
		self.tmpDirURL = try ProcessTemporaryDirectory.shared.makeDirectory()
		let dbURL = tmpDirURL.appending(component: "db.sqlite", directoryHint: .notDirectory)
		self.directoryContentCache = try DirectoryContentDBCache(fileAt: dbURL, maxPageSize: maxPageSize)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	// MARK: - CloudProvider API

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		try cloudPath.checkResolvable()
		return try await getItemMetadata(at: cloudPath)
	}

	/// Doesn't check for cancellation, so that an upload can still fetch the metadata to return after its remote change.
	private func getItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		do {
			let (response, data) = try await client.PROPFIND(url: url, depth: .zero, propertyNames: WebDAVCloudProvider.defaultPropertyNames)
			guard let data else {
				throw WebDAVProviderError.invalidResponse
			}
			try checkMarkup { try WebDAVXMLGuard.validate(data) }
			let parser = PropfindResponseParser(XMLParser(data: data), responseURL: response.url ?? url)
			guard let element = try parser.getRequestedElement() else {
				throw WebDAVProviderError.invalidResponse
			}
			return CloudItemMetadata(element, cloudPath: cloudPath)
		} catch WebDAVError.httpError(statusCode: 405) {
			// Workaround for: https://github.com/nextcloud/server/issues/34574
			throw CloudProviderError.itemNotFound
		} catch {
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		try cloudPath.checkResolvable()
		do {
			if let pageToken {
				return try directoryContentCache.getPage(for: cloudPath, pageToken: pageToken)
			}
			return try await publishPropfindResponseSnapshot(forFolderAt: cloudPath)
		} catch WebDAVError.httpError(statusCode: 405) {
			// Workaround for: https://github.com/nextcloud/server/issues/34574
			throw CloudProviderError.itemNotFound
		} catch {
			throw convertStandardError(error)
		}
	}

	private func publishPropfindResponseSnapshot(forFolderAt cloudPath: CloudPath) async throws -> CloudItemList {
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		let tmpFileURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
		defer {
			try? FileManager.default.removeItem(at: tmpFileURL)
		}
		let response = try await client.PROPFIND(url: url, depth: .one, to: tmpFileURL, propertyNames: WebDAVCloudProvider.defaultPropertyNames)
		try Task.checkCancellation()
		try checkMarkup { try WebDAVXMLGuard.validate(fileAt: tmpFileURL) }
		let responseURL = response.url ?? url
		guard let inputStream = InputStream(url: tmpFileURL) else {
			throw WebDAVProviderError.invalidResponse
		}
		return try await directoryContentCache.publishSnapshot(of: cloudPath) { snapshot in
			let parser = CachePropfindResponseParser(XMLParser(stream: inputStream), responseURL: responseURL, cache: directoryContentCache, snapshot: snapshot)
			try parser.fillCache()
			inputStream.close()
		}
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		try cloudPath.checkResolvable()
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
		let localFile = try LocalUploadFile(localURL)
		try cloudPath.checkAsTarget()
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		let phases = Progress.phases(of: progress, 999)
		do {
			// A PUT request on an existing file succeeds regardless of `replaceExisting`, so the metadata is fetched first to make that distinction.
			do {
				let metadata = try await getItemMetadata(at: cloudPath)
				if !replaceExisting || metadata.itemType == .folder {
					throw CloudProviderError.itemAlreadyExists
				}
			} catch CloudProviderError.itemNotFound {
				// no-op
			}
			try Task.checkCancellation()
			_ = try await client.PUT(url: url, fileURL: localFile.url, progress: phases[0], onTaskCreation: onTaskCreation)
		} catch {
			switch error {
			case WebDAVError.httpError(statusCode: 409), WebDAVError.httpError(statusCode: 404):
				throw CloudProviderError.parentFolderDoesNotExist
			case WebDAVError.httpError(statusCode: 507):
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
		try cloudPath.checkAsTarget()
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		do {
			_ = try await client.MKCOL(url: url)
		} catch {
			switch error {
			case WebDAVError.httpError(statusCode: 404):
				// RFC 4918 reports a missing parent of a MKCOL as 409 and lists no 404 for it, so a 404 stays raw instead of claiming that an item is missing.
				throw error
			case WebDAVError.httpError(statusCode: 405):
				throw CloudProviderError.itemAlreadyExists
			case WebDAVError.httpError(statusCode: 409):
				throw CloudProviderError.parentFolderDoesNotExist
			case WebDAVError.httpError(statusCode: 507):
				throw CloudProviderError.quotaInsufficient
			default:
				throw convertStandardError(error)
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
		try cloudPath.checkAsSource()
		guard let url = URL(cloudPath: cloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		do {
			_ = try await client.DELETE(url: url)
		} catch is WebDAVMemberFailure {
			throw CloudProviderError.deletionIncomplete
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
		try sourceCloudPath.checkAsSource()
		try targetCloudPath.checkAsTarget()
		guard let sourceURL = URL(cloudPath: sourceCloudPath, relativeTo: client.baseURL), let targetURL = URL(cloudPath: targetCloudPath, relativeTo: client.baseURL) else {
			throw WebDAVProviderError.resolvingURLFailed
		}
		do {
			_ = try await client.MOVE(sourceURL: sourceURL, destinationURL: targetURL)
		} catch {
			switch error {
			case let memberFailure as WebDAVMemberFailure:
				// The target isn't known to be complete, so this isn't `moveCompletedWithSourceRemaining`.
				throw WebDAVError.httpError(statusCode: memberFailure.statusCode)
			case WebDAVError.httpError(statusCode: 409), WebDAVError.httpError(statusCode: 415):
				// SabreDAV answers a destination whose parent is missing with 409, and one whose parent is no collection with 415.
				throw CloudProviderError.parentFolderDoesNotExist
			case WebDAVError.httpError(statusCode: 412):
				throw CloudProviderError.itemAlreadyExists
			case WebDAVError.httpError(statusCode: 507):
				throw CloudProviderError.quotaInsufficient
			default:
				throw convertStandardError(error)
			}
		}
	}

	private func checkMarkup(_ check: () throws -> Void) throws {
		do {
			try check()
		} catch let error as WebDAVXMLGuardError {
			CloudAccessDDLogDebug("WebDAVCloudProvider: refused response markup: \(error)")
			switch error {
			case .limitExceeded:
				throw WebDAVProviderError.responseTooLarge
			case .unsupported:
				throw WebDAVProviderError.invalidResponse
			}
		}
	}

	func convertStandardError(_ error: Error) -> Error {
		switch error {
		case WebDAVError.httpError(statusCode: 401):
			// A rejected credential arrives as 401. A 403 concerns the item or the share (e.g., a read-only share), and editing the account can't fix it.
			return CloudProviderError.unauthorized
		case WebDAVError.httpError(statusCode: 404):
			return CloudProviderError.itemNotFound
		default:
			return convertingNetworkConnectionError(error)
		}
	}
}
