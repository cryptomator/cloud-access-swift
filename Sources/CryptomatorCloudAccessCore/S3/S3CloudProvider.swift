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
	/// The file size above which an upload is a multipart upload. It defaults to the largest part, so that every file up to that size is uploaded in a single task, which can run on while an app extension is suspended.
	private let multipartUploadThreshold: Int
	private let minPartSize: Int
	private let maxPartCount: Int
	fileprivate static let delimiter = "/"
	private static let fileContentType = "application/octet-stream"
	private static let folderContentType = "application/x-directory"
	private static let s3MaxPageSize = 1000

	init(client: S3Client, maxPageSize: Int, multipartUploadThreshold: Int = S3Client.maxPartSize, minPartSize: Int = 32 * 1024 * 1024, maxPartCount: Int = S3Client.maxPartCount) {
		self.client = client
		self.copyUtility = S3CopyTaskUtility(client: client)
		self.maxPageSize = min(max(1, maxPageSize), S3CloudProvider.s3MaxPageSize)
		self.multipartUploadThreshold = multipartUploadThreshold
		self.minPartSize = minPartSize
		self.maxPartCount = maxPartCount
	}

	/**
	 Creates an S3 provider whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.

	 - Parameter sharedContainerIdentifier: The container into which the background URL session downloads files, which an app extension must share with its app, or `nil` in the app.
	 - Throws: `URLError(.badURL)` if the credential's URL isn't an absolute HTTP or HTTPS URL with a host.
	 */
	public static func withBackgroundSession(credential: S3Credential, maxPageSize: Int = .max, sessionIdentifier: String, sharedContainerIdentifier: String?) throws -> S3CloudProvider {
		return try S3CloudProvider(client: .background(credential: credential, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier), maxPageSize: maxPageSize)
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
		return try await perform("fetchItemMetadata(at: \(cloudPath.path))") {
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
		}
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		return try await perform("fetchItemList(forFolderAt: \(cloudPath.path), withPageToken: \(pageToken ?? "nil"))") {
			let prefix = getPrefix(for: cloudPath)
			let output: S3ListObjectsResult
			do {
				// A folder's marker counts toward `max-keys`, so the first page of a folder that has one holds one item fewer. Asking for one more key would let every other page exceed `maxPageSize`.
				output = try await listObjects(withPrefix: prefix, recursive: false, pageToken: pageToken, maxKeys: maxPageSize)
			} catch {
				throw await checkContinuationTokenForInvalidity(continuationToken: pageToken, folderPath: cloudPath, error: error)
			}
			CloudAccessDDLogDebug("S3CloudProvider: fetchItemList(forFolderAt: \(cloudPath.path), withPageToken: \(pageToken ?? "nil")) received output: \(output)")
			let itemList = CloudItemList(listObjects: output, listedPrefix: prefix)
			// Any key with the prefix, also one that the item list leaves out, proves that the folder exists, although the page may hold no item. Without one, the folder may also be missing or a file.
			let hasKeyWithPrefix = output.contents.contains(where: { $0.key.deletingPrefix(prefix) != nil }) || output.commonPrefixes.contains(where: { $0.deletingPrefix(prefix) != nil })
			if !hasKeyWithPrefix, cloudPath != .root {
				try await assertFolderExists(at: cloudPath)
			}
			return itemList
		}
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		return try await perform("downloadFile(from: \(cloudPath.path), to: \(localURL))") {
			let key = getKey(for: cloudPath)
			let phases = Progress.phases(of: progress, 999)
			let remoteMetadata = try await getItemMetadata(at: cloudPath)
			guard remoteMetadata.itemType == .file else {
				throw CloudProviderError.itemTypeMismatch
			}
			try Task.checkCancellation()
			let metadata = try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
				do {
					try await client.download(key: key, to: stagedFile, progress: phases[0], onTaskCreation: onTaskCreation)
				} catch let error as S3Error where error.isObjectGone {
					throw CloudProviderError.itemNotFound
				}
				return remoteMetadata
			})
			CloudAccessDDLogDebug("S3CloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) finished")
			phases.completeTransfer()
			return metadata
		}
	}

	/// A file of more than 4768 MiB is uploaded as a multipart upload, whose part tasks aren't passed to `onTaskCreation`.
	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		return try await perform("uploadFile(from: \(localURL), to: \(cloudPath.path), replaceExisting: \(replaceExisting))") {
			let localFile = try LocalUploadFile(localURL)
			let fileSize = Int(localFile.size)
			let partSize = try multipartUploadPartSize(forFileSize: fileSize)
			let key = getKey(for: cloudPath)
			let phases = Progress.phases(of: progress, 999)
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
			if let partSize {
				try await uploadLargeFile(from: localFile.url, key: key, fileSize: fileSize, partSize: partSize, progress: phases[0])
			} else {
				try await client.upload(key: key, fromFile: localFile.url, contentType: S3CloudProvider.fileContentType, progress: phases[0], onTaskCreation: onTaskCreation)
			}
			CloudAccessDDLogDebug("S3CloudProvider: uploadFile(from: \(localURL), to: \(cloudPath.path), replaceExisting: \(replaceExisting)) finished, fetching metadata…")
			// The upload committed with its PUT or its completion, so the metadata is fetched even if the task is cancelled meanwhile.
			let metadata = try await withoutCancellation {
				try await self.getItemMetadata(at: cloudPath)
			}
			phases.completeTransfer()
			return metadata
		}
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await perform("createFolder(at: \(cloudPath.path))") {
			if try await checkForItemExistence(at: cloudPath) {
				throw CloudProviderError.itemAlreadyExists
			}
			try await assertParentFolderExists(for: cloudPath)
			try Task.checkCancellation()
			// S3 has no folders, so a folder is a 0-byte object whose key is the folder path with a trailing slash.
			try await client.putEmptyObject(key: getKey(for: cloudPath) + S3CloudProvider.delimiter, contentType: S3CloudProvider.folderContentType)
			CloudAccessDDLogDebug("S3CloudProvider: createFolder(at: \(cloudPath.path)) finished")
		}
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await perform("deleteFile(at: \(cloudPath.path))") {
			_ = try await getItemMetadata(at: cloudPath)
			try Task.checkCancellation()
			if try await isDeletionRefused(client.deleteObject(key: getKey(for: cloudPath))) {
				throw CloudProviderError.deletionIncomplete
			}
			CloudAccessDDLogDebug("S3CloudProvider: deleteFile(at: \(cloudPath.path)) finished")
		}
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await perform("deleteFolder(at: \(cloudPath.path))") {
			_ = try await getItemMetadata(at: cloudPath)
			try await deleteFolderAfterCheck(at: cloudPath)
			CloudAccessDDLogDebug("S3CloudProvider: deleteFolder(at: \(cloudPath.path)) finished")
		}
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await perform("moveFile(from: \(sourceCloudPath.path), to: \(targetCloudPath.path))") {
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
				if try await self.isDeletionRefused(self.client.deleteObject(key: sourceKey)) {
					throw CloudProviderError.moveCompletedWithSourceRemaining
				}
			}
			CloudAccessDDLogDebug("S3CloudProvider: moveFile(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) finished")
		}
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await perform("moveFolder(from: \(sourceCloudPath.path), to: \(targetCloudPath.path))") {
			try await assertItemDoesExist(at: sourceCloudPath)
			try await assertItemDoesNotExist(at: targetCloudPath)
			try await assertParentFolderExists(for: targetCloudPath)
			try Task.checkCancellation()
			try await withoutCancellation {
				try await self.moveFolderAfterCheck(from: sourceCloudPath, to: targetCloudPath)
			}
			CloudAccessDDLogDebug("S3CloudProvider: moveFolder(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) finished")
		}
	}

	/**
	 Moves a folder from `sourceCloudPath` to `targetCloudPath` after various preconditions have already been met.

	 Since S3 does not support move directly, this must be realized via a copy followed by a delete of the source object. For folders, this needs to be done for each individual object with the prefix of `sourceCloudPath`, and only objects that were copied are deleted. An object without a size is copied in a single request, as `moveFile` does.

	 S3 refusing to delete source objects, or a whole `DeleteObjects` request, doesn't stop the move, so that every page is copied.

	 - Throws: `CloudProviderError.moveCompletedWithSourceRemaining` after copying every page if S3 refused to delete source objects. A failed listing or copy, or a transport failure of a `DeleteObjects` request, is thrown at once.
	 */
	func moveFolderAfterCheck(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		let sourcePrefix = getPrefix(for: sourceCloudPath)
		let targetPrefix = getPrefix(for: targetCloudPath)
		var hasSourceRemaining = false
		try await forEachRecursivePage(prefix: sourcePrefix) { objects in
			let copyRequests: [S3CopyRequest] = objects.compactMap {
				guard let name = $0.key.deletingPrefix(sourcePrefix) else {
					return nil
				}
				let targetKey = targetPrefix + name
				return .init(sourceKey: $0.key, targetKey: targetKey, itemSize: $0.size ?? 0)
			}
			try await copyUtility.copy(copyRequests)
			if try await isDeletionRefused(client.deleteObjects(keys: copyRequests.map(\.sourceKey))) {
				hasSourceRemaining = true
			}
		}
		if hasSourceRemaining {
			throw CloudProviderError.moveCompletedWithSourceRemaining
		}
	}

	/**
	 Checks for continuation token invalidity.

	 As not every S3 provider returns the same error message if the continuation token is invalid, we first try to convert the passed error to a `CloudProviderError.pageTokenInvalid`.
	 Rejected credentials and a missing connection say nothing about the continuation token, so `unauthorized` and `noInternetConnection` are returned as they are.
	 For every other error, we check if the folder exists at the passed `folderPath`, which the root always does. If this is the case, we assume that the request failed because of an invalid continuation token.

	 - Returns: The error with which the request for the item list fails.
	 */
	func checkContinuationTokenForInvalidity(continuationToken: String?, folderPath: CloudPath, error: Error) async -> Error {
		let convertedError = convertStandardError(error)
		guard continuationToken != nil, !(convertedError is CancellationError) else {
			return convertedError
		}
		switch convertedError {
		case CloudProviderError.pageTokenInvalid, CloudProviderError.unauthorized, CloudProviderError.noInternetConnection:
			return convertedError
		default:
			break
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

	// - MARK: Multipart Upload

	/**
	 Returns the part size of a multipart upload of a file with the given size, or `nil` if the file is uploaded with one request.

	 - Throws: `URLError(.dataLengthExceedsMaximum)` if the file needs parts larger than `S3Client.maxPartSize`.
	 */
	private func multipartUploadPartSize(forFileSize fileSize: Int) throws -> Int? {
		guard fileSize > multipartUploadThreshold else {
			return nil
		}
		let partSize = S3CloudProvider.partSize(forFileSize: fileSize, minPartSize: minPartSize, maxPartCount: maxPartCount)
		guard partSize <= S3Client.maxPartSize else {
			throw URLError(.dataLengthExceedsMaximum)
		}
		return partSize
	}

	/// Returns the part size of a multipart upload of a file with the given size: `minPartSize`, or, if the file needs more than `maxPartCount` parts of that size, the smallest whole number of MiB that fits it into `maxPartCount` parts.
	static func partSize(forFileSize fileSize: Int, minPartSize: Int, maxPartCount: Int) -> Int {
		let mebibyte = 1024 * 1024
		let partSize = (fileSize + maxPartCount - 1) / maxPartCount
		guard partSize > minPartSize else {
			return minPartSize
		}
		return (partSize + mebibyte - 1) / mebibyte * mebibyte
	}

	/// Uploads the file as a multipart upload, one part after the other, each from a temporary file, so that no part is held in memory. The progress counts bytes, so each part's share is its length.
	private func uploadLargeFile(from localURL: URL, key: String, fileSize: Int, partSize: Int, progress: Progress?) async throws {
		progress?.totalUnitCount = Int64(fileSize)
		try await client.multipartUpload(key: key, contentType: S3CloudProvider.fileContentType) { uploadID in
			let fileHandle = try FileHandle(forReadingFrom: localURL)
			defer {
				try? fileHandle.close()
			}
			var parts = [S3CompletedPart]()
			var offset = 0
			while offset < fileSize {
				try Task.checkCancellation()
				let expectedLength = min(partSize, fileSize - offset)
				try fileHandle.seek(toOffset: UInt64(offset))
				let (partFileURL, partLength) = try HTTPClientSupport.writeTemporaryFile(copyingUpTo: expectedLength, from: fileHandle)
				defer {
					try? FileManager.default.removeItem(at: partFileURL)
				}
				guard partLength == expectedLength else {
					// The file got shorter during the upload, which must not complete a shorter object.
					throw CocoaError(.fileReadCorruptFile)
				}
				let partNumber = parts.count + 1
				let eTag = try await client.uploadPart(key: key, uploadID: uploadID, partNumber: partNumber, fromFile: partFileURL, progress: progress?.makeExplicitChild(pendingUnitCount: Int64(partLength)))
				parts.append((partNumber: partNumber, eTag: eTag))
				offset += partLength
			}
			return parts
		}
	}

	// - MARK: Requests

	/// Leaves out the keys and common prefixes that don't start with the prefix, which only a server that ignores the prefix returns, so that a folder move or deletion never touches a key outside its folder.
	private func listObjects(withPrefix prefix: String, recursive: Bool, pageToken: String?, maxKeys: Int = S3CloudProvider.s3MaxPageSize) async throws -> S3ListObjectsResult {
		let result = try await client.listObjectsV2(prefix: prefix, delimiter: recursive ? nil : S3CloudProvider.delimiter, continuationToken: pageToken, maxKeys: maxKeys)
		let hasPrefix: (String) -> Bool = { key in
			guard key.deletingPrefix(prefix) != nil else {
				CloudAccessDDLogDebug("S3CloudProvider: skipping key \(key), because it doesn't start with the listed prefix \(prefix)")
				return false
			}
			return true
		}
		return S3ListObjectsResult(contents: result.contents.filter { hasPrefix($0.key) }, commonPrefixes: result.commonPrefixes.filter(hasPrefix), nextContinuationToken: result.nextContinuationToken)
	}

	func getKey(for cloudPath: CloudPath) -> String {
		if cloudPath == .root {
			return ""
		}
		var path = cloudPath.path
		if path.unicodeScalars.first == "/" {
			path.unicodeScalars.removeFirst()
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

	// - MARK: Error Conversion

	/// Logs the operation and converts the errors that it throws.
	private func perform<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
		try await performLogged(operation, by: "S3CloudProvider", convert: convertStandardError, body)
	}

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
		case "AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "InvalidSignatureException", "AuthFailure", "AccessDeniedException", "AuthMissingFailure", "InvalidClientTokenId", "MissingAuthenticationToken", "ExpiredToken", "InvalidToken", "TokenRefreshRequired", "InvalidTokenId", "InvalidSecurity":
			return CloudProviderError.unauthorized
		case "Unauthorized" where error.statusCode == 401:
			// Cloudflare R2's code for rejected credentials. With a 403, it was reported for a CORS failure.
			return CloudProviderError.unauthorized
		case S3Error.noSuchKeyCode:
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

	 S3 refusing to delete objects, or a whole `DeleteObjects` request, doesn't stop the deletion, so that every page is deleted that can be.

	 - Throws: `CloudProviderError.deletionIncomplete` after every page if S3 refused to delete objects. Once S3 refused, any later failure but cancellation throws it as well. An error answer to an earlier attempt of a batch counts as a refusal, so a failure without an answer that ends that batch throws it too.
	 */
	func deleteFolderAfterCheck(at cloudPath: CloudPath) async throws {
		var isIncomplete = false
		do {
			try await forEachRecursivePage(prefix: getPrefix(for: cloudPath)) { objects in
				let outcome = try await client.deleteObjects(keys: objects.map(\.key))
				if case let .unknown(error, answeredBefore: true) = outcome {
					isIncomplete = true
					throw error
				}
				if try isDeletionRefused(outcome) {
					isIncomplete = true
				}
			}
		} catch where isIncomplete && !(error is CancellationError) {
			CloudAccessDDLogDebug("S3CloudProvider: deleteFolder(at: \(cloudPath.path)) failed after S3 refused to delete objects: \(error)")
			throw CloudProviderError.deletionIncomplete
		}
		if isIncomplete {
			throw CloudProviderError.deletionIncomplete
		}
	}

	/// Passes each page of the recursive listing below the prefix to `body`. It checks for cancellation before each listing and each `body`, so a caller past its commit point runs it in `withoutCancellation`.
	private func forEachRecursivePage(prefix: String, _ body: ([S3Object]) async throws -> Void) async throws {
		var nextContinuationToken: String?
		repeat {
			try Task.checkCancellation()
			let listObjects = try await listObjects(withPrefix: prefix, recursive: true, pageToken: nextContinuationToken)
			try Task.checkCancellation()
			try await body(listObjects.contents)
			nextContinuationToken = listObjects.nextContinuationToken
		} while nextContinuationToken != nil
	}

	/**
	 Returns whether S3 refused the deletion, which it logs.

	 - Throws: The failure of a deletion whose outcome is unknown.
	 */
	private func isDeletionRefused(_ outcome: S3DeletionOutcome) throws -> Bool {
		switch outcome {
		case .deleted:
			return false
		case let .refused(.members(failures)):
			let examples = failures.prefix(10).map { "\($0.key ?? "nil") (\($0.code ?? "nil"))" }.joined(separator: ", ")
			CloudAccessDDLogDebug("S3CloudProvider: S3 refused to delete \(failures.count) objects, e.g., \(examples)")
			return true
		case let .refused(.request(error)):
			CloudAccessDDLogDebug("S3CloudProvider: S3 refused the deletion request: \(error)")
			return true
		case let .unknown(error, _):
			throw error
		}
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

	func assertFolderExists(at cloudPath: CloudPath) async throws {
		let metadata = try await fetchItemMetadata(at: cloudPath)
		guard metadata.itemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
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
		let itemType: CloudItemType = object.key.unicodeScalars.last == "/" ? .folder : .file
		let cloudPath = CloudPath(S3CloudProvider.delimiter + object.key)
		self.init(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: object.lastModified.flatMap(Date.date(fromISO8601:)), size: object.size)
	}
}

extension CloudItemList {
	/// Leaves out the keys and common prefixes that no cloud path addresses. For the listing of a prefix, it also leaves out the folder's own marker, which S3 lists with the folder's items. It leaves out those that aren't directly below the prefix, too, which only a server that ignores the delimiter or the prefix returns.
	init(listObjects: S3ListObjectsResult, listedPrefix: String? = nil) {
		let subFolders: [CloudItemMetadata] = listObjects.commonPrefixes.filter { CloudItemList.isAddressable($0, listedPrefix: listedPrefix) }.map { prefix in
			let subFolderCloudPath = CloudPath(S3CloudProvider.delimiter + prefix)
			return CloudItemMetadata(name: subFolderCloudPath.lastPathComponent, cloudPath: subFolderCloudPath, itemType: .folder, lastModifiedDate: nil, size: nil)
		}
		var items = listObjects.contents.filter { CloudItemList.isAddressable($0.key, listedPrefix: listedPrefix) }.map { CloudItemMetadata(object: $0) }
		items.append(contentsOf: subFolders)
		self.init(items: items, nextPageToken: listObjects.nextContinuationToken)
	}

	/// Whether a cloud path addresses the key: every segment, after dropping one trailing slash, is a single path component. Any other key, e.g., `a//b`, `a/../b` or `/a`, would standardize to a cloud path that names another key. With a listed prefix, the key must also be an item of that listing: directly below the prefix, and not the folder's own marker.
	private static func isAddressable(_ key: String, listedPrefix: String?) -> Bool {
		var segments = key.pathSegments()
		if segments.count > 1, segments.last == "" {
			segments.removeLast()
		}
		guard segments.allSatisfy(\.isSinglePathComponent) else {
			CloudAccessDDLogDebug("S3CloudProvider: skipping key \(key), because one of its segments is no single path component")
			return false
		}
		guard let listedPrefix else {
			return true
		}
		guard let remainder = key.deletingPrefix(listedPrefix) else {
			CloudAccessDDLogDebug("S3CloudProvider: skipping key \(key), because it doesn't start with the listed prefix \(listedPrefix)")
			return false
		}
		// The remainder is empty for the folder's marker.
		guard !remainder.isEmpty else {
			return false
		}
		// A key directly below the prefix holds a slash at most at its end.
		guard !remainder.unicodeScalars.dropLast().contains("/") else {
			CloudAccessDDLogDebug("S3CloudProvider: skipping key \(key), because it isn't directly below the listed prefix \(listedPrefix)")
			return false
		}
		return true
	}
}

private extension String {
	/// Compares bytes, as S3 does, because a `Character` can span the end of the prefix.
	func deletingPrefix(_ prefix: String) -> String? {
		guard utf8.starts(with: prefix.utf8) else {
			return nil
		}
		return String(Substring(utf8.dropFirst(prefix.utf8.count)))
	}
}
