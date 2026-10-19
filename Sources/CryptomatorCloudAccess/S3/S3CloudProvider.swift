//
//  S3CloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 30.05.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

public final class S3CloudProvider: CloudProvider {
	private let client: S3Client
	private let copyUtility: S3CopyTaskUtility
	private let maxPageSize: Int
	private static let delimiter = "/"
	private static let folderContentType = "application/x-directory"
	private static let s3MaxPageSize = 1000

	init(client: S3Client, maxPageSize: Int) {
		self.client = client
		self.copyUtility = S3CopyTaskUtility(client: client)
		self.maxPageSize = min(max(1, maxPageSize), S3CloudProvider.s3MaxPageSize)
	}

	/**
	 Creates an S3 provider whose downloads and uploads run on a background URL session, and whose other requests run on a foreground URL session.

	 If the provider is used in an app extension, set the `sharedContainerIdentifier` to a valid identifier for a container that will be shared between the app and the extension.

	 - Throws: `URLError(.badURL)` if the credential's URL isn't an absolute HTTP or HTTPS URL with a host.
	 */
	public static func withBackgroundSession(credential: S3Credential, sharedContainerIdentifier: String?, maxPageSize: Int = .max) throws -> S3CloudProvider {
		return try S3CloudProvider(client: .background(credential: credential, sharedContainerIdentifier: sharedContainerIdentifier), maxPageSize: maxPageSize)
	}

	/// - Throws: `URLError(.badURL)` if the credential's URL isn't an absolute HTTP or HTTPS URL with a host.
	public convenience init(credential: S3Credential, maxPageSize: Int = .max) throws {
		try self.init(client: .foreground(credential: credential), maxPageSize: maxPageSize)
	}

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		return try await getItemMetadata(at: cloudPath)
	}

	/// Lists the item's key as prefix (without trailing slash) instead of sending a `headObject` request, because some providers don't respond to that with an access denied error. A sibling such as `a/b 2/` or `a/b.txt` sorts before the folder `a/b/`, so when the first page holds only a sibling, the folder's own prefix is listed as well.
	private func getItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("S3CloudProvider: fetchItemMetadata(at: \(cloudPath.path)) called")
		do {
			let output = try await listObjects(withPrefix: getKey(for: cloudPath), recursive: false, pageToken: nil, maxKeys: 1)
			CloudAccessDDLogDebug("S3CloudProvider: fetchItemMetadata(at: \(cloudPath.path)) received output: \(output)")
			if let item = CloudItemList(listObjects: output).items.first(where: { $0.cloudPath == cloudPath }) {
				return item
			}
			guard cloudPath != .root, output.nextContinuationToken != nil else {
				throw CloudProviderError.itemNotFound
			}
			try Task.checkCancellation()
			let folderOutput = try await listObjects(withPrefix: getPrefix(for: cloudPath), recursive: false, pageToken: nil, maxKeys: 1)
			guard !folderOutput.contents.isEmpty || !folderOutput.commonPrefixes.isEmpty else {
				throw CloudProviderError.itemNotFound
			}
			return CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .folder, lastModifiedDate: nil, size: nil)
		} catch {
			CloudAccessDDLogDebug("S3CloudProvider: fetchItemMetadata(at: \(cloudPath.path)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		CloudAccessDDLogDebug("S3CloudProvider: fetchItemList(forFolderAt: \(cloudPath.path), withPageToken: \(pageToken ?? "nil")) called")
		do {
			let output: S3ListObjectsResult
			do {
				// The listing includes the folder itself.
				output = try await listObjects(withPrefix: getPrefix(for: cloudPath), recursive: false, pageToken: pageToken, maxKeys: maxPageSize + 1)
			} catch {
				throw await checkContinuationTokenForInvalidity(continuationToken: pageToken, folderPath: cloudPath, error: error)
			}
			CloudAccessDDLogDebug("S3CloudProvider: fetchItemList(forFolderAt: \(cloudPath.path), withPageToken: \(pageToken ?? "nil")) received output: \(output)")
			let itemList = removeParentFolderFrom(itemList: CloudItemList(listObjects: output), parentFolderPath: cloudPath)
			try await validateItemList(itemList, folderPath: cloudPath)
			return itemList
		} catch {
			CloudAccessDDLogDebug("S3CloudProvider: fetchItemList(forFolderAt: \(cloudPath.path), withPageToken: \(pageToken ?? "nil")) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		CloudAccessDDLogDebug("S3CloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) called")
		let key = getKey(for: cloudPath)
		let phases = Progress.phases(of: progress, 999)
		do {
			let remoteMetadata = try await getItemMetadata(at: cloudPath)
			guard remoteMetadata.itemType == .file else {
				throw CloudProviderError.itemTypeMismatch
			}
			try Task.checkCancellation()
			let metadata = try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
				do {
					try await client.download(key: key, to: stagedFile, progress: phases[0], onTaskCreation: onTaskCreation)
				} catch let error as S3Error where error.statusCode == 404 {
					// The error body of a download may be missing or too long to read, so any 404 means that the file is gone.
					throw CloudProviderError.itemNotFound
				}
				return remoteMetadata
			})
			CloudAccessDDLogDebug("S3CloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) finished")
			phases.completeTransfer()
			return metadata
		} catch {
			CloudAccessDDLogDebug("S3CloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		CloudAccessDDLogDebug("S3CloudProvider: uploadFile(from: \(localURL), to: \(cloudPath.path), replaceExisting: \(replaceExisting)) called")
		var isDirectory: ObjCBool = false
		let fileExists = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
		if !fileExists {
			throw CloudProviderError.itemNotFound
		}
		if isDirectory.boolValue {
			throw CloudProviderError.itemTypeMismatch
		}
		let resourceKey: URLResourceKey = if #available(iOS 14.0, *) {
			.contentTypeKey
		} else {
			.typeIdentifierKey
		}
		let resourceValues = try localURL.resourceValues(forKeys: [resourceKey])
		let maybeContentType = resourceValues.typeIdentifier
		let contentType = maybeContentType ?? "application/octet-stream"
		let key = getKey(for: cloudPath)
		let phases = Progress.phases(of: progress, 999)
		do {
			do {
				let metadata = try await getItemMetadata(at: cloudPath)
				guard replaceExisting, metadata.itemType == .file else {
					throw CloudProviderError.itemAlreadyExists
				}
			} catch CloudProviderError.itemNotFound {
				try await assertParentFolderExists(for: cloudPath)
			}
			try Task.checkCancellation()
			CloudAccessDDLogDebug("S3CloudProvider: uploadFile(from: \(localURL), to: \(cloudPath.path), replaceExisting: \(replaceExisting)) precondition done, uploading file…")
			try await client.upload(key: key, fromFile: localURL, contentType: contentType, progress: phases[0], onTaskCreation: onTaskCreation)
			CloudAccessDDLogDebug("S3CloudProvider: uploadFile(from: \(localURL), to: \(cloudPath.path), replaceExisting: \(replaceExisting)) finished, fetching metadata…")
			// The upload committed with its PUT, so the metadata is fetched even if the task is cancelled meanwhile.
			let metadata = try await withoutCancellation {
				try await self.getItemMetadata(at: cloudPath)
			}
			phases.completeTransfer()
			return metadata
		} catch {
			CloudAccessDDLogDebug("S3CloudProvider: uploadFile(from: \(localURL), to: \(cloudPath.path), replaceExisting: \(replaceExisting)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		CloudAccessDDLogDebug("S3CloudProvider: createFolder(at: \(cloudPath.path)) called")
		do {
			if try await checkForItemExistence(at: cloudPath) {
				throw CloudProviderError.itemAlreadyExists
			}
			try await assertParentFolderExists(for: cloudPath)
			try Task.checkCancellation()
			// S3 has no folders, so a folder is a 0-byte object whose key is the folder path with a trailing slash.
			try await client.putEmptyObject(key: getKey(for: cloudPath) + S3CloudProvider.delimiter, contentType: S3CloudProvider.folderContentType)
			CloudAccessDDLogDebug("S3CloudProvider: createFolder(at: \(cloudPath.path)) finished")
		} catch {
			CloudAccessDDLogDebug("S3CloudProvider: createFolder(at: \(cloudPath.path)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		CloudAccessDDLogDebug("S3CloudProvider: deleteFile(at: \(cloudPath.path)) called")
		do {
			_ = try await getItemMetadata(at: cloudPath)
			try Task.checkCancellation()
			try await client.deleteObject(key: getKey(for: cloudPath))
			CloudAccessDDLogDebug("S3CloudProvider: deleteFile(at: \(cloudPath.path)) finished")
		} catch {
			CloudAccessDDLogDebug("S3CloudProvider: deleteFile(at: \(cloudPath.path)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		CloudAccessDDLogDebug("S3CloudProvider: deleteFolder(at: \(cloudPath.path)) called")
		do {
			_ = try await getItemMetadata(at: cloudPath)
			try await deleteFolderAfterCheck(at: cloudPath)
		} catch {
			CloudAccessDDLogDebug("S3CloudProvider: deleteFolder(at: \(cloudPath.path)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		CloudAccessDDLogDebug("S3CloudProvider: moveFile(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) called")
		do {
			let metadata = try await getItemMetadata(at: sourceCloudPath)
			try await assertItemDoesNotExist(at: targetCloudPath)
			try await assertParentFolderExists(for: targetCloudPath)
			let itemSize = metadata.size ?? 0
			let sourceKey = getKey(for: sourceCloudPath)
			let targetKey = getKey(for: targetCloudPath)
			let copyRequest = S3CopyRequest(sourceKey: sourceKey, targetKey: targetKey, itemSize: itemSize)
			try Task.checkCancellation()
			try await withoutCancellation {
				try await self.copyUtility.copy(copyRequest)
				try await self.deleteFile(at: sourceCloudPath)
			}
			CloudAccessDDLogDebug("S3CloudProvider: moveFile(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) finished")
		} catch {
			CloudAccessDDLogDebug("S3CloudProvider: moveFile(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		CloudAccessDDLogDebug("S3CloudProvider: moveFolder(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) called")
		do {
			try await assertItemDoesExist(at: sourceCloudPath)
			try await assertItemDoesNotExist(at: targetCloudPath)
			try await assertParentFolderExists(for: targetCloudPath)
			try Task.checkCancellation()
			try await withoutCancellation {
				try await self.moveFolderAfterCheck(from: sourceCloudPath, to: targetCloudPath)
			}
			CloudAccessDDLogDebug("S3CloudProvider: moveFolder(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) finished")
		} catch {
			CloudAccessDDLogDebug("S3CloudProvider: moveFolder(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	/**
	 Moves a folder from `sourceCloudPath` to `targetCloudPath` after various preconditions have already been met.

	 Since S3 does not support move directly, this must be realized via a copy followed by a delete of the source object. For folders, this needs to be done for each individual object with the prefix of the given `folderPath`.
	 */
	func moveFolderAfterCheck(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		let parentSourceKey = getKey(for: sourceCloudPath)
		let parentTargetKey = getKey(for: targetCloudPath)
		var nextContinuationToken: String?
		repeat {
			let listObjects = try await listObjects(withPrefix: getPrefix(for: sourceCloudPath), recursive: true, pageToken: nextContinuationToken)
			let copyRequests: [S3CopyRequest] = listObjects.contents.compactMap {
				guard let name = $0.key.deletingPrefix(parentSourceKey), let itemSize = $0.size else {
					return nil
				}
				let targetKey = parentTargetKey + name
				return .init(sourceKey: $0.key, targetKey: targetKey, itemSize: itemSize)
			}
			try await withThrowingTaskGroup(of: Void.self) { group in
				for copyRequest in copyRequests {
					group.addTask {
						try await self.copyUtility.copy(copyRequest)
					}
				}
				try await group.waitForAll()
			}

			try await deleteObjects(keys: listObjects.contents.map(\.key))

			nextContinuationToken = listObjects.nextContinuationToken
		} while nextContinuationToken != nil
	}

	/**
	 Checks for continuation token invalidity.

	 As not every S3 provider returns the same error message if the continuation token is invalid, we first try to convert the passed error to a `CloudProviderError.pageTokenInvalid`.
	 If the conversion fails because we don't know the error, we check if the folder exists at the passed `folderPath`. If this is the case, we assume that the request failed because of an invalid continuation token.

	 - Returns: The error with which the request for the item list fails.
	 */
	func checkContinuationTokenForInvalidity(continuationToken: String?, folderPath: CloudPath, error: Error) async -> Error {
		let convertedError = convertStandardError(error)
		guard continuationToken != nil, !(convertedError is CancellationError) else {
			return convertedError
		}
		if case CloudProviderError.pageTokenInvalid = convertedError {
			return convertedError
		}
		if folderPath == .root {
			return CloudProviderError.pageTokenInvalid
		}
		do {
			_ = try await fetchItemMetadata(at: folderPath)
			return CloudProviderError.pageTokenInvalid
		} catch let metadataError {
			return metadataError
		}
	}

	/**
	 Validates the given `CloudItemList`.

	 Since S3 realizes the concept of a folder via the prefixes of the files, empty folders can be realized via a 0-byte file with this prefix - for example, when creating a new folder using the AWS S3 Console.
	 However, S3 also returns an empty list if the folder does not exist at all. Therefore, in case of an empty list, the existence of the 0-byte file must be checked by a `fetchItemMetadata(at:)` call for the given `folderPath`.
	 */
	func validateItemList(_ itemList: CloudItemList, folderPath: CloudPath) async throws {
		if !itemList.items.isEmpty || folderPath == .root {
			return
		}
		let metadata = try await fetchItemMetadata(at: folderPath)
		guard metadata.itemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
	}

	// - MARK: Requests

	private func listObjects(withPrefix prefix: String, recursive: Bool, pageToken: String?, maxKeys: Int = S3CloudProvider.s3MaxPageSize) async throws -> S3ListObjectsResult {
		return try await client.listObjectsV2(prefix: prefix, delimiter: recursive ? nil : S3CloudProvider.delimiter, continuationToken: pageToken, maxKeys: maxKeys)
	}

	func getKey(for cloudPath: CloudPath, isFolder: Bool = false) -> String {
		if cloudPath == .root {
			return ""
		}
		var path = cloudPath.path
		if path.hasPrefix("/") {
			path.removeFirst()
		}
		if isFolder, !path.hasSuffix("/") {
			path += "/"
		}
		return path
	}

	func getPrefix(for cloudPath: CloudPath) -> String {
		let key = getKey(for: cloudPath)
		if cloudPath == .root {
			return key
		}
		return key + S3CloudProvider.delimiter
	}

	/**
	 Removes the folder corresponding given `parentFolderPath` from the given `itemList`.

	 Since S3 includes the folder itself in the resulting list for a `listObjectsV2` request, it has to be removed again afterwards.
	 */
	func removeParentFolderFrom(itemList: CloudItemList, parentFolderPath: CloudPath) -> CloudItemList {
		var items = itemList.items
		items.removeAll(where: { $0.cloudPath == parentFolderPath && $0.itemType == .folder })
		return CloudItemList(items: items, nextPageToken: itemList.nextPageToken)
	}

	// - MARK: Error Conversion

	func convertStandardError(_ error: Error) -> Error {
		if error is CloudProviderError || error is CancellationError {
			return error
		}
		if isNetworkConnectionError(error) {
			return CloudProviderError.noInternetConnection
		}
		if let s3Error = error as? S3Error {
			return convertS3Error(s3Error)
		}
		let nsError = error as NSError
		if nsError.domain == kCFErrorDomainCFNetwork as String, nsError.code == CFNetworkErrors.cfErrorHTTPParseFailure.rawValue {
			// workaround as some providers (e.g. Scaleway) return sometimes an 303 HTTP Error instead of an access denied
			return CloudProviderError.unauthorized
		}
		return error
	}

	func convertS3Error(_ error: S3Error) -> Error {
		switch error.code {
		case "AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "InvalidSignatureException", "AuthFailure", "AccessDeniedException", "AuthMissingFailure", "InvalidClientTokenId", "MissingAuthenticationToken":
			return CloudProviderError.unauthorized
		case "ExpiredToken", "InvalidToken", "TokenRefreshRequired":
			return CloudProviderError.pageTokenInvalid
		case "NoSuchKey":
			return CloudProviderError.itemNotFound
		case "InvalidArgument" where error.argumentName == "continuation-token":
			return CloudProviderError.pageTokenInvalid
		case "InternalError" where error.reason == "Incorrect padding":
			return CloudProviderError.pageTokenInvalid
		case nil where error.statusCode == 401 || error.statusCode == 403:
			return CloudProviderError.unauthorized
		default:
			return error
		}
	}

	// - MARK: Delete

	/**
	 Recursively deletes a folder at the given path after its existence has already been checked.

	 Since S3 has no folders, this needs to be done for each individual object with the prefix of the given `cloudPath`.
	 */
	func deleteFolderAfterCheck(at cloudPath: CloudPath) async throws {
		var nextContinuationToken: String?
		repeat {
			try Task.checkCancellation()
			CloudAccessDDLogDebug("S3CloudProvider: deleteFolder(at: \(cloudPath.path), continuationToken: \(nextContinuationToken ?? "nil")) called")
			let listObjects = try await listObjects(withPrefix: getPrefix(for: cloudPath), recursive: true, pageToken: nextContinuationToken)
			try Task.checkCancellation()
			try await deleteObjects(keys: listObjects.contents.map(\.key))
			CloudAccessDDLogDebug("S3CloudProvider: deleteFolder(at: \(cloudPath.path), continuationToken: \(nextContinuationToken ?? "nil")) finished")
			nextContinuationToken = listObjects.nextContinuationToken
		} while nextContinuationToken != nil
	}

	/// The errors of single objects are ignored, so that a folder of which S3 refused to delete some objects counts as deleted.
	func deleteObjects(keys: [String]) async throws {
		if keys.isEmpty {
			return
		}
		try await client.deleteObjects(keys: keys)
	}

	// - MARK: Assertions

	func assertParentFolderExists(for cloudPath: CloudPath) async throws {
		CloudAccessDDLogDebug("S3CloudProvider: assertParentFolderExists(for: \(cloudPath.path)) called")
		let parentPath = cloudPath.deletingLastPathComponent()
		if parentPath == .root {
			return
		}
		do {
			let metadata = try await fetchItemMetadata(at: parentPath)
			guard metadata.itemType == .folder else {
				throw CloudProviderError.itemTypeMismatch
			}
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}

	func assertItemDoesNotExist(at cloudPath: CloudPath) async throws {
		CloudAccessDDLogDebug("S3CloudProvider: assertItemDoesNotExist(at: \(cloudPath.path)) called")
		if try await checkForItemExistence(at: cloudPath) {
			throw CloudProviderError.itemAlreadyExists
		}
	}

	func assertItemDoesExist(at cloudPath: CloudPath) async throws {
		CloudAccessDDLogDebug("S3CloudProvider: assertItemDoesExist(at: \(cloudPath.path)) called")
		guard try await checkForItemExistence(at: cloudPath) else {
			throw CloudProviderError.itemNotFound
		}
	}
}

extension CloudItemMetadata {
	init(object: S3Object) {
		let itemType: CloudItemType = object.key.hasSuffix("/") ? .folder : .file
		let path = object.key.hasPrefix("/") ? object.key : "/" + object.key
		let cloudPath = CloudPath(path)
		self.init(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: object.lastModified, size: object.size)
	}
}

extension CloudItemList {
	init(listObjects: S3ListObjectsResult) {
		let subFolders: [CloudItemMetadata] = listObjects.commonPrefixes.map { prefix in
			let path = prefix.hasPrefix("/") ? prefix : "/" + prefix
			let subFolderCloudPath = CloudPath(path)
			return CloudItemMetadata(name: subFolderCloudPath.lastPathComponent, cloudPath: subFolderCloudPath, itemType: .folder, lastModifiedDate: nil, size: nil)
		}
		var items = listObjects.contents.map { CloudItemMetadata(object: $0) }
		items.append(contentsOf: subFolders)
		self.init(items: items, nextPageToken: listObjects.nextContinuationToken)
	}
}

extension CloudPath {
	static var root: CloudPath {
		return CloudPath("/")
	}
}

private extension String {
	func deletingPrefix(_ prefix: String) -> String? {
		guard hasPrefix(prefix) else {
			return nil
		}
		return String(dropFirst(prefix.count))
	}
}
