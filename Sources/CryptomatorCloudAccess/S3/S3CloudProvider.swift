//
//  S3CloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 30.05.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AWSCore
@preconcurrency import AWSS3
import CocoaLumberjackSwift
import Foundation

enum S3CloudProviderError: Error {
	case invalidRequest
	case missingTransferUtility
	case serviceConfigurationInitFailed
}

public final class S3CloudProvider: CloudProvider {
	private let transferUtility: AWSS3TransferUtility
	private let service: AWSS3
	private let credential: S3Credential
	private let copyUtility: S3CopyTaskUtility
	private let maxPageSize: Int
	private static let delimiter = "/"
	private static let folderContentType = "application/x-directory"
	private static let s3MaxPageSize = 1000

	init(credential: S3Credential, useBackgroundSession: Bool, transferUtilityConfiguration: AWSS3TransferUtilityConfiguration, serviceConfiguration: AWSServiceConfiguration, maxPageSize: Int) throws {
		self.credential = credential
		AWSEndpoint.exchangeRegionNameImplementation
		CustomAWSEndpointRegionNameStorage.shared.setRegionName(credential.region, for: credential)
		AWSS3TransferUtility.register(with: serviceConfiguration, transferUtilityConfiguration: transferUtilityConfiguration, forKey: credential.identifier)
		AWSS3.register(with: serviceConfiguration, forKey: credential.identifier)
		guard let transferUtility = AWSS3TransferUtility.s3TransferUtility(forKey: credential.identifier) else {
			throw S3CloudProviderError.missingTransferUtility
		}
		if !useBackgroundSession {
			AWSS3TransferUtility.useForegroundURLSession(for: transferUtility)
		}
		self.transferUtility = transferUtility
		let service = AWSS3.s3(forKey: credential.identifier)
		self.copyUtility = S3CopyTaskUtility(service: service, bucket: credential.bucket)
		self.service = service
		self.maxPageSize = min(max(1, maxPageSize), S3CloudProvider.s3MaxPageSize)
	}

	public static func withBackgroundSession(credential: S3Credential, sharedContainerIdentifier: String?, maxPageSize: Int = .max) throws -> S3CloudProvider {
		try S3CloudProvider(credential: credential, useBackgroundSession: true, sharedContainerIdentifier: sharedContainerIdentifier, maxPageSize: maxPageSize)
	}

	public convenience init(credential: S3Credential, maxPageSize: Int = .max) throws {
		try self.init(credential: credential, useBackgroundSession: false, sharedContainerIdentifier: nil, maxPageSize: maxPageSize)
	}

	convenience init(credential: S3Credential, useBackgroundSession: Bool, sharedContainerIdentifier: String?, maxPageSize: Int) throws {
		let endpoint = AWSEndpoint(url: credential.url)
		let credentialsProvider = AWSStaticCredentialsProvider(accessKey: credential.accessKey, secretKey: credential.secretKey)
		let region = credential.region.aws_regionTypeValue()
		guard let serviceConfiguration = AWSServiceConfiguration(region: region, endpoint: endpoint, credentialsProvider: credentialsProvider) else {
			throw S3CloudProviderError.serviceConfigurationInitFailed
		}
		serviceConfiguration.sharedContainerIdentifier = sharedContainerIdentifier
		let transferUtilityConfiguration = AWSS3TransferUtilityConfiguration()
		transferUtilityConfiguration.bucket = credential.bucket
		try self.init(credential: credential, useBackgroundSession: useBackgroundSession, transferUtilityConfiguration: transferUtilityConfiguration, serviceConfiguration: serviceConfiguration, maxPageSize: maxPageSize)
	}

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		return try await getItemMetadata(at: cloudPath)
	}

	/**
	 Use a `listObjectsV2` request with the cloudPath as prefix (without trailing slash) instead of a `headObject` request as some providers do not respond with an access denied error.

	 Doesn't check for cancellation, so that an upload can still fetch the metadata to return after its remote change.
	 */
	private func getItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("S3CloudProvider: fetchItemMetadata(at: \(cloudPath.path)) called")
		let request = createListObjectsV2Request(for: cloudPath, recursive: false, pageToken: nil, maxKeys: 1)
		guard var prefix = request.prefix else {
			throw S3CloudProviderError.invalidRequest
		}
		if prefix != getPrefix(for: .root), prefix.hasSuffix(S3CloudProvider.delimiter) {
			prefix.removeLast(1)
		}
		request.prefix = prefix
		do {
			let output = try await service.executeListObjectsV2(request)
			CloudAccessDDLogDebug("S3CloudProvider: fetchItemMetadata(at: \(cloudPath.path)) received output: \(output)")
			guard let item = CloudItemList(listObjects: output).items.first(where: { $0.cloudPath == cloudPath }) else {
				throw CloudProviderError.itemNotFound
			}
			return item
		} catch {
			CloudAccessDDLogDebug("S3CloudProvider: fetchItemMetadata(at: \(cloudPath.path)) failed with error: \(error)")
			throw convertStandardError(error)
		}
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		CloudAccessDDLogDebug("S3CloudProvider: fetchItemList(forFolderAt: \(cloudPath.path), withPageToken: \(pageToken ?? "nil")) called")
		let request = createListObjectsV2Request(for: cloudPath, recursive: false, pageToken: pageToken)
		request.maxKeys = NSNumber(value: maxPageSize + 1) // request includes the folder itself
		do {
			let output: AWSS3ListObjectsV2Output
			do {
				output = try await service.executeListObjectsV2(request)
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
					try await transferUtility.download(to: stagedFile, key: key, expression: .init())
				} catch {
					throw await recoverDownloadFailure(error, metadataCheck: { try await assertFileExists(at: cloudPath) })
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
			try await transferUtility.uploadFile(localURL, key: key, contentType: contentType, expression: .init())
			CloudAccessDDLogDebug("S3CloudProvider: uploadFile(from: \(localURL), to: \(cloudPath.path), replaceExisting: \(replaceExisting)) finished, fetching metadata…")
			let metadata = try await getItemMetadata(at: cloudPath)
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
		let request = createEmptyFolderPutObjectRequest(for: cloudPath)
		request.contentType = S3CloudProvider.folderContentType
		do {
			if try await checkForItemExistence(at: cloudPath) {
				throw CloudProviderError.itemAlreadyExists
			}
			try await assertParentFolderExists(for: cloudPath)
			try Task.checkCancellation()
			let output = try await service.executePutObject(request)
			CloudAccessDDLogDebug("S3CloudProvider: createFolder(at: \(cloudPath.path)) received output: \(output)")
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
			let request = createDeleteObjectRequest(for: cloudPath)
			let output = try await service.executeDeleteObject(request)
			CloudAccessDDLogDebug("S3CloudProvider: deleteFile(at: \(cloudPath.path)) received output: \(output)")
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
			let request = createListObjectsV2Request(for: sourceCloudPath, recursive: true, pageToken: nextContinuationToken)
			let listObjects = try await service.executeListObjectsV2(request)

			let contents: [AWSS3Object] = listObjects.contents ?? []
			let keys: [String] = contents.compactMap(\.key)
			assert(contents.count == keys.count)

			let copyRequests: [S3CopyRequest] = contents.compactMap {
				guard let sourceKey = $0.key, let name = sourceKey.deletingPrefix(parentSourceKey), let itemSize = $0.size?.intValue else {
					return nil
				}
				let targetKey = parentTargetKey + name
				return .init(sourceKey: sourceKey, targetKey: targetKey, itemSize: itemSize)
			}
			try await withThrowingTaskGroup(of: Void.self) { group in
				for copyRequest in copyRequests {
					group.addTask {
						try await self.copyUtility.copy(copyRequest)
					}
				}
				try await group.waitForAll()
			}

			let deleteObjectsRequest = createDeleteObjectsRequest(keys: keys)
			_ = try await deleteObjects(deleteObjectsRequest)

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

	func assertFileExists(at cloudPath: CloudPath) async throws {
		let metadata = try await fetchItemMetadata(at: cloudPath)
		guard metadata.itemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
	}

	/**
	 Maps the error of a failed download. As the transfer doesn't report whether the file is missing, this is determined by a metadata check.

	 - Parameter error: The error of the transfer.
	 - Parameter metadataCheck: Throws if there is no file at the remote path. Not called if the download was cancelled.
	 - Returns: The error of `metadataCheck` if it throws, otherwise `error`.
	 */
	func recoverDownloadFailure(_ error: Error, metadataCheck: () async throws -> Void) async -> Error {
		if error is CancellationError {
			return error
		}
		do {
			try await metadataCheck()
			return error
		} catch let metadataError {
			return metadataError
		}
	}

	// - MARK: Requests

	func createListObjectsV2Request(for cloudPath: CloudPath, recursive: Bool, pageToken: String?, maxKeys: Int = 1000) -> AWSS3ListObjectsV2Request {
		let request = AWSS3ListObjectsV2Request()!
		request.bucket = credential.bucket
		request.prefix = getPrefix(for: cloudPath)
		if !recursive {
			request.delimiter = S3CloudProvider.delimiter
		}
		request.continuationToken = pageToken
		request.maxKeys = NSNumber(value: maxKeys)
		return request
	}

	func createDeleteObjectRequest(for cloudPath: CloudPath) -> AWSS3DeleteObjectRequest {
		let request = AWSS3DeleteObjectRequest()!
		request.bucket = credential.bucket
		request.key = getKey(for: cloudPath)
		return request
	}

	func createDeleteObjectsRequest(keys: [String]) -> AWSS3DeleteObjectsRequest {
		let request = AWSS3DeleteObjectsRequest()!
		request.bucket = credential.bucket
		let removeContainer = AWSS3Remove()
		let identifiers = keys.compactMap { key -> AWSS3ObjectIdentifier? in
			let identifier = AWSS3ObjectIdentifier()
			identifier?.key = key
			return identifier
		}
		assert(keys.count == identifiers.count)
		removeContainer?.objects = identifiers
		request.remove = removeContainer
		return request
	}

	/**
	 Creates a `putObject` request for an empty folder.

	 Empty folders are represented in S3 due to the flat structure via a 0-byte file with the folder path incl. trailing slash.
	 */
	func createEmptyFolderPutObjectRequest(for cloudPath: CloudPath) -> AWSS3PutObjectRequest {
		let request = AWSS3PutObjectRequest()!
		request.bucket = credential.bucket
		request.key = getKey(for: cloudPath) + S3CloudProvider.delimiter
		request.body = nil
		return request
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

	func convertStandardError(_ error: Error, mapUnknownErrorTo unknownError: Error? = nil) -> Error {
		if error is CloudProviderError {
			return error
		}
		if isNetworkConnectionError(error) {
			return CloudProviderError.noInternetConnection
		}
		let nsError = error as NSError
		switch (nsError.domain, nsError.code) {
		case (AWSServiceErrorDomain, _):
			return convertAWSServiceError(nsError, unknownError: unknownError)
		case (AWSS3ErrorDomain, _):
			return convertAWSS3Error(nsError, unknownError: unknownError)
		case let (domain, code) where domain == kCFErrorDomainCFNetwork as String && code == CFNetworkErrors.cfErrorHTTPParseFailure.rawValue:
			// workaround as some providers (e.g. Scaleway) return sometimes an 303 HTTP Error instead of an access denied
			return CloudProviderError.unauthorized
		default:
			return error
		}
	}

	func convertAWSServiceError(_ error: NSError, unknownError: Error?) -> Error {
		switch AWSServiceErrorType(rawValue: error.code) {
		case .accessDenied, .accessDeniedException, .authFailure, .authMissingFailure, .invalidAccessKeyId, .invalidClientTokenId, .missingAuthenticationToken, .invalidSignatureException, .signatureDoesNotMatch:
			return CloudProviderError.unauthorized
		case .expiredToken, .invalidToken, .tokenRefreshRequired:
			return CloudProviderError.pageTokenInvalid
		case .unknown:
			return unknownError ?? error
		default:
			return error
		}
	}

	func convertAWSS3Error(_ error: NSError, unknownError: Error?) -> Error {
		switch AWSS3ErrorType(rawValue: error.code) {
		case .noSuchKey:
			return CloudProviderError.itemNotFound
		case .unknown:
			guard let convertedError = convertUnknownAWSS3Error(error) else {
				return unknownError ?? error
			}
			return convertedError
		default:
			return error
		}
	}

	func convertUnknownAWSS3Error(_ error: NSError) -> Error? {
		let userInfo = error.userInfo
		if userInfo["Code"] as? String == "InvalidArgument", userInfo["ArgumentName"] as? String == "continuation-token" {
			return CloudProviderError.pageTokenInvalid
		}
		if userInfo["Code"] as? String == "InternalError", userInfo["Reason"] as? String == "Incorrect padding" {
			return CloudProviderError.pageTokenInvalid
		}
		return nil
	}

	func convertStandardError<T>(_ error: Error, mapUnknownErrorTo unknownError: Error) throws -> T {
		let convertedError = convertStandardError(error, mapUnknownErrorTo: unknownError)
		throw convertedError
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
			let request = createListObjectsV2Request(for: cloudPath, recursive: true, pageToken: nextContinuationToken)
			let listObjects = try await service.executeListObjectsV2(request)
			let contents: [AWSS3Object] = listObjects.contents ?? []
			let keys: [String] = contents.compactMap(\.key)
			assert(contents.count == keys.count)
			try Task.checkCancellation()
			let deleteObjectsRequest = createDeleteObjectsRequest(keys: keys)
			let output = try await deleteObjects(deleteObjectsRequest)
			CloudAccessDDLogDebug("S3CloudProvider: deleteFolder(at: \(cloudPath.path), continuationToken: \(nextContinuationToken ?? "nil")) received output: \(output)")
			nextContinuationToken = listObjects.nextContinuationToken
		} while nextContinuationToken != nil
	}

	func deleteObjects(_ request: AWSS3DeleteObjectsRequest) async throws -> AWSS3DeleteObjectsOutput {
		guard let objects = request.remove?.objects else {
			throw S3CloudProviderError.invalidRequest
		}
		if objects.isEmpty {
			return AWSS3DeleteObjectsOutput()
		}
		return try await service.executeDeleteObjects(request)
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
	init(headObject: AWSS3HeadObjectOutput, key: String) {
		let itemType: CloudItemType = key.hasSuffix("/") ? .folder : .file
		let path = key.hasPrefix("/") ? key : "/" + key
		let cloudPath = CloudPath(path)
		self.init(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: headObject.lastModified, size: headObject.contentLength?.intValue)
	}

	init?(object: AWSS3Object) {
		guard let key = object.key else {
			return nil
		}
		let itemType: CloudItemType = key.hasSuffix("/") ? .folder : .file
		let path = key.hasPrefix("/") ? key : "/" + key
		let cloudPath = CloudPath(path)
		self.init(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: object.lastModified, size: object.size?.intValue)
	}
}

extension CloudItemList {
	init(listObjects: AWSS3ListObjectsV2Output) {
		let subFolders: [CloudItemMetadata] = listObjects.commonPrefixes?.compactMap {
			guard let prefix = $0.prefix else {
				return nil
			}
			let path = prefix.hasPrefix("/") ? prefix : "/" + prefix
			let subFolderCloudPath = CloudPath(path)
			return CloudItemMetadata(name: subFolderCloudPath.lastPathComponent, cloudPath: subFolderCloudPath, itemType: .folder, lastModifiedDate: nil, size: nil)
		} ?? []
		let contents: [AWSS3Object] = listObjects.contents ?? []
		let files: [CloudItemMetadata] = contents.compactMap { CloudItemMetadata(object: $0) }
		var items = files
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
