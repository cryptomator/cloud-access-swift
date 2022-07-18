//
//  S3CloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 30.05.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import AWSCore
import AWSS3
import CocoaLumberjackSwift
import Foundation
import Promises

enum S3CloudProviderError: Error {
	case invalidRequest
	case missingTransferUtility
	case serviceConfigurationInitFailed
}

public class S3CloudProvider: CloudProvider {
	private let transferUtility: AWSS3TransferUtility
	private let service: AWSS3
	private let credential: S3Credential
	private let copyUtility: S3CopyTaskUtility
	private let maxPageSize: Int
	private static let delimiter = "/"
	private static let folderContentType = "application/x-directory"
	private static let s3MaxPageSize = 1000

	init(credential: S3Credential,
	     useBackgroundSession: Bool,
	     transferUtilityConfiguration: AWSS3TransferUtilityConfiguration,
	     serviceConfiguration: AWSServiceConfiguration,
	     maxPageSize: Int) throws {
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

	// Use a `listObjectsV2` request with the cloudPath as prefix (without trailing slash) instead of an headObject request as some providers do not answer with an access denied error
	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		let request = createListObjectsV2Request(for: cloudPath, recursive: false, pageToken: nil, maxKeys: 1)
		guard var prefix = request.prefix else {
			return Promise(S3CloudProviderError.invalidRequest)
		}
		if prefix != getPrefix(for: .root), prefix.hasSuffix(S3CloudProvider.delimiter) {
			prefix.removeLast(1)
		}
		request.prefix = prefix
		return service.listObjectsV2(request).then { output in
			return CloudItemList(listObjects: output)
		}.then { itemList -> CloudItemMetadata in
			guard let item = itemList.items.first(where: { $0.cloudPath == cloudPath }) else {
				throw CloudProviderError.itemNotFound
			}
			return item
		}.recover { error -> CloudItemMetadata in
			throw self.convertStandardError(error)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		let request = createListObjectsV2Request(for: cloudPath, recursive: false, pageToken: pageToken)
		// request includes the folder itself
		request.maxKeys = NSNumber(value: maxPageSize + 1)
		return service.listObjectsV2(request)
			.recover { error -> Promise<AWSS3ListObjectsV2Output> in
				return self.checkContinuationTokenForInvalidity(continuationToken: pageToken, folderPath: cloudPath, error: error)
			}.then { listObjects -> CloudItemList in
				return CloudItemList(listObjects: listObjects)
			}.then { itemList -> Promise<(CloudItemList, Void)> in
				let cleanedItemList = self.removeParentFolderFrom(itemList: itemList, parentFolderPath: cloudPath)
				return all(Promise(cleanedItemList), self.validateItemList(cleanedItemList, folderPath: cloudPath))
			}.then { itemList, _ in
				return itemList
			}.recover { error -> CloudItemList in
				throw self.convertStandardError(error)
			}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		if FileManager.default.fileExists(atPath: localURL.path) {
			return Promise(CloudProviderError.itemAlreadyExists)
		}
		let key = getKey(for: cloudPath)
		return transferUtility.download(to: localURL, key: key, expression: .init()).recover { _ -> Promise<Void> in
			return self.assertFileExists(at: cloudPath)
		}.recover { error -> Void in
			throw self.convertStandardError(error)
		}
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		CloudAccessDDLogDebug("start upload file at: \(cloudPath.path) - \(Date())")
		var isDirectory: ObjCBool = false
		let fileExists = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
		if !fileExists {
			return Promise(CloudProviderError.itemNotFound)
		}
		if isDirectory.boolValue {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		let contentType: String
		do {
			let resourceKey: URLResourceKey
			if #available(iOS 14.0, *) {
				resourceKey = .contentTypeKey
			} else {
				resourceKey = .typeIdentifierKey
			}
			let resourceValues = try localURL.resourceValues(forKeys: [resourceKey])
			let maybeContentType = resourceValues.typeIdentifier
			contentType = maybeContentType ?? "application/octet-stream"
		} catch {
			return Promise(error)
		}
		let key = getKey(for: cloudPath)
		return fetchItemMetadata(at: cloudPath).then { metadata -> Void in
			guard replaceExisting, metadata.itemType == .file else {
				throw CloudProviderError.itemAlreadyExists
			}
		}.recover { error -> Promise<Void> in
			CloudAccessDDLogDebug("fetchItemMetadata (precondition) failed with error: \(error)")
			guard case CloudProviderError.itemNotFound = error else {
				return Promise(error)
			}
			return self.assertParentFolderExists(for: cloudPath)
		}.then { _ -> Promise<AWSS3TransferUtilityUploadTask> in
			CloudAccessDDLogDebug("precondition done - start upload file at: \(cloudPath.path)")
			return self.transferUtility.uploadFile(localURL, key: key, contentType: contentType, expression: .init())
		}.then { _ -> Promise<CloudItemMetadata> in
			CloudAccessDDLogDebug("finished upload file at: \(cloudPath.path) - fetching metadata…")
			return self.fetchItemMetadata(at: cloudPath)
		}.then { metadata -> CloudItemMetadata in
			CloudAccessDDLogDebug("finished upload file at: \(cloudPath.path))")
			return metadata
		}.recover { error -> CloudItemMetadata in
			throw self.convertStandardError(error)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		let request = createEmptyFolderPutObjectRequest(for: cloudPath)
		request.contentType = S3CloudProvider.folderContentType
		CloudAccessDDLogDebug("start creating folder at: \(cloudPath.path)")
		return checkForItemExistence(at: cloudPath).then { folderExists -> Promise<Void> in
			if folderExists {
				return Promise(CloudProviderError.itemAlreadyExists)
			}
			return self.assertParentFolderExists(for: cloudPath)
		}.then { _ -> Promise<AWSS3PutObjectOutput> in
			return self.service.putObject(request)
		}.then { _ -> Void in
			// no-op
			CloudAccessDDLogDebug("finished creating folder at: \(cloudPath.path)")
		}.recover { error -> Void in
			throw self.convertStandardError(error)
		}
	}

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		return fetchItemMetadata(at: cloudPath).then { _ -> Promise<AWSS3DeleteObjectOutput> in
			let request = self.createDeleteObjectRequest(for: cloudPath)
			return self.service.deleteObject(request)
		}.then { _ in
			// no-op
		}.recover { error -> Void in
			throw self.convertStandardError(error)
		}
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return fetchItemMetadata(at: cloudPath).then { _ in
			return self.deleteFolder(at: cloudPath, continuationToken: nil)
		}.then { _ in
			// no-op
		}.recover { error -> Void in
			throw self.convertStandardError(error)
		}
	}

	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return all(fetchItemMetadata(at: sourceCloudPath), assertItemDoesNotExist(at: targetCloudPath), assertParentFolderExists(for: targetCloudPath)).then { metadata, _, _ -> Promise<Void> in
			let itemSize = metadata.size ?? 0
			let sourceKey = self.getKey(for: sourceCloudPath)
			let targetKey = self.getKey(for: targetCloudPath)
			let copyRequest = S3CopyRequest(sourceKey: sourceKey, targetKey: targetKey, itemSize: itemSize)
			return self.copyUtility.copy(copyRequest)
		}.then { _ -> Promise<Void> in
			return self.deleteFile(at: sourceCloudPath)
		}.recover { error -> Void in
			throw self.convertStandardError(error)
		}
	}

	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return all(assertItemDoesExist(at: sourceCloudPath), assertItemDoesNotExist(at: targetCloudPath), assertParentFolderExists(for: targetCloudPath)).then { _, _, _ in
			return self.moveFolderAfterCheck(from: sourceCloudPath, to: targetCloudPath)
		}.recover { error -> Void in
			throw self.convertStandardError(error)
		}
	}

	/**
	 Moves a folder from `sourceCloudPath` to `targetCloudPath` after various preconditions have already been met.

	 Since S3 does not support move directly, this must be realized via a copy followed by a delete of the source object. For folders this needs to be done for each individual object with the prefix of the given `folderPath`.
	 */
	func moveFolderAfterCheck(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		let parentSourceKey = getKey(for: sourceCloudPath)
		let parentTargetKey = getKey(for: targetCloudPath)
		return Promise<Void>(on: .global()) { fulfill, _ in
			var nextContinuationToken: String?
			repeat {
				let request = self.createListObjectsV2Request(for: sourceCloudPath, recursive: true, pageToken: nextContinuationToken)
				let listObjects = try awaitPromise(self.service.listObjectsV2(request))

				let contents: [AWSS3Object] = listObjects.contents ?? []
				let keys: [String] = contents.compactMap { $0.key }
				assert(contents.count == keys.count)

				let copyRequests: [S3CopyRequest] = contents.compactMap {
					guard let sourceKey = $0.key, let name = sourceKey.deletingPrefix(parentSourceKey), let itemSize = $0.size?.intValue else {
						return nil
					}
					let targetKey = parentTargetKey + name
					return .init(sourceKey: sourceKey, targetKey: targetKey, itemSize: itemSize)
				}
				let copyPromises = copyRequests.map { self.copyUtility.copy($0) }
				_ = try awaitPromise(all(copyPromises))

				let deleteObjectsRequest = self.createDeleteObjectsRequest(keys: keys)
				_ = try awaitPromise(all(self.deleteObjects(deleteObjectsRequest)))

				nextContinuationToken = listObjects.nextContinuationToken
			} while nextContinuationToken != nil
			fulfill(())
		}
	}

	/**
	 Checks for continuation token invalidity.

	 As not every S3 provider returns the same error message if the continuation token is invalid, we first try to convert the passed error to a `CloudProviderError.pageTokenInvalid`.
	 If the conversion fails, because we don't know the error, we check if the folder exists at the passed `folderPath`, if this is the case we assume that the request failed because of an invalid continuation token.
	 */
	func checkContinuationTokenForInvalidity<T>(continuationToken: String?, folderPath: CloudPath, error: Error) -> Promise<T> {
		let convertedError = convertStandardError(error)
		guard continuationToken != nil else {
			return Promise(convertedError)
		}
		if case CloudProviderError.pageTokenInvalid = convertedError {
			return Promise(convertedError)
		}
		if folderPath == .root {
			return Promise(CloudProviderError.pageTokenInvalid)
		}
		return fetchItemMetadata(at: folderPath).then { _ -> T in
			throw CloudProviderError.pageTokenInvalid
		}
	}

	/**
	 Validates the given `CloudItemList`

	 Since S3 realizes the concept of a folder via the prefixes of the files, empty folders can be realized via a 0-byte file with this prefix - for example, when creating a new folder using the AWS S3 Console.
	 However, S3 also returns an empty list if the folder does not exist at all. Therefore, in case of an empty list, the existence of the 0 byte file must be checked by a `fetchItemMetadata(at:)` call for the given `folderPath`.
	 */
	func validateItemList(_ itemList: CloudItemList, folderPath: CloudPath) -> Promise<Void> {
		if !itemList.items.isEmpty || folderPath == .root {
			return Promise(())
		}
		return fetchItemMetadata(at: folderPath).then { metadata -> Void in
			guard metadata.itemType == .folder else {
				throw CloudProviderError.itemTypeMismatch
			}
		}
	}

	func assertFileExists(at cloudPath: CloudPath) -> Promise<Void> {
		return fetchItemMetadata(at: cloudPath).then { metadata -> Void in
			guard metadata.itemType == .file else {
				throw CloudProviderError.itemTypeMismatch
			}
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
	 Creates a put object request for an empty folder.

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

	 Since S3 with a` listObjectsV2` request the folder itself also occurs in the resulting list, it has to be removed again afterwards.
	 */
	func removeParentFolderFrom(itemList: CloudItemList, parentFolderPath: CloudPath) -> CloudItemList {
		var items = itemList.items
		items.removeAll(where: { $0.cloudPath == parentFolderPath && $0.itemType == .folder })
		return CloudItemList(items: items, nextPageToken: itemList.nextPageToken)
	}

	// - MARK: Error conversion

	func convertStandardError(_ error: Error, mapUnknownErrorTo unknownError: Error? = nil) -> Error {
		if error is CloudProviderError {
			return error
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
	 Recursively deletes a folder at the given path.

	 Since S3 has
	 */
	func deleteFolder(at cloudPath: CloudPath, continuationToken: String?) -> Promise<String?> {
		let request = createListObjectsV2Request(for: cloudPath, recursive: true, pageToken: continuationToken)
		return service.listObjectsV2(request).then { listObjects -> Promise<(Void, String?)>in
			let contents: [AWSS3Object] = listObjects.contents ?? []
			let keys: [String] = contents.compactMap { $0.key }
			assert(contents.count == keys.count)
			let deleteObjectsRequest = self.createDeleteObjectsRequest(keys: keys)
			return all(self.deleteObjects(deleteObjectsRequest), Promise(listObjects.nextContinuationToken))
		}.then { _, continuationToken -> Promise<String?> in
			guard let continuationToken = continuationToken else {
				return Promise(nil)
			}
			return self.deleteFolder(at: cloudPath, continuationToken: continuationToken)
		}
	}

	func deleteObjects(_ request: AWSS3DeleteObjectsRequest) -> Promise<Void> {
		guard let objects = request.remove?.objects else {
			return Promise(S3CloudProviderError.invalidRequest)
		}
		if objects.isEmpty {
			return Promise(())
		}
		return service.deleteObjects(request).then { _ in
			// no-op
		}
	}

	// - MARK: Assertions

	func assertParentFolderExists(for cloudPath: CloudPath) -> Promise<Void> {
		let parentPath = cloudPath.deletingLastPathComponent()
		if parentPath == .root {
			return Promise(())
		}
		return fetchItemMetadata(at: parentPath).then { metadata -> Void in
			guard metadata.itemType == .folder else {
				throw CloudProviderError.itemTypeMismatch
			}
		}.recover { error -> Void in
			if case CloudProviderError.itemNotFound = error {
				throw CloudProviderError.parentFolderDoesNotExist
			} else {
				throw error
			}
		}
	}

	func assertItemDoesNotExist(at cloudPath: CloudPath) -> Promise<Void> {
		checkForItemExistence(at: cloudPath).then { itemExists -> Void in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}
	}

	func assertItemDoesExist(at cloudPath: CloudPath) -> Promise<Void> {
		checkForItemExistence(at: cloudPath).then { itemExists -> Void in
			if !itemExists {
				throw CloudProviderError.itemNotFound
			}
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
