//
//  MicrosoftGraphCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import MSGraphClientModels
@preconcurrency import MSGraphClientSDK

/// Safe to share across threads, because the requests of both HTTP clients are issued on the main actor.
public final class MicrosoftGraphCloudProvider: CloudProvider {
	private static let maxUploadFileChunkLength = 16 * 320 * 1024 // 5MiB

	private let client: MSHTTPClient
	private let unauthenticatedClient: MSHTTPClient
	private let driveIdentifier: String?
	private let identifierCache: MicrosoftGraphIdentifierCache
	private let tmpDirURL: URL
	private let maxPageSize: Int

	init(credential: MicrosoftGraphCredential, driveIdentifier: String? = nil, maxPageSize: Int = .max, urlSessionConfiguration: URLSessionConfiguration, unauthenticatedURLSessionConfiguration: URLSessionConfiguration) throws {
		self.client = MSClientFactory.createHTTPClient(with: credential.authProvider, andSessionConfiguration: urlSessionConfiguration)
		self.unauthenticatedClient = MSClientFactory.createUnauthenticatedHTTPClient(with: unauthenticatedURLSessionConfiguration)
		self.driveIdentifier = driveIdentifier
		self.identifierCache = try MicrosoftGraphIdentifierCache()
		self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		self.maxPageSize = min(max(1, maxPageSize), 1000)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	public convenience init(credential: MicrosoftGraphCredential, driveIdentifier: String? = nil, maxPageSize: Int = .max) throws {
		try self.init(credential: credential, driveIdentifier: driveIdentifier, maxPageSize: maxPageSize, urlSessionConfiguration: .default, unauthenticatedURLSessionConfiguration: .default)
	}

	public static func withBackgroundSession(credential: MicrosoftGraphCredential, driveIdentifier: String? = nil, maxPageSize: Int = .max, sessionIdentifier: String) throws -> MicrosoftGraphCloudProvider {
		let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
		configuration.sharedContainerIdentifier = MicrosoftGraphSetup.constants.sharedContainerIdentifier
		let unauthenticatedConfiguration = URLSessionConfiguration.background(withIdentifier: "\(sessionIdentifier)_unauthenticated")
		unauthenticatedConfiguration.sharedContainerIdentifier = MicrosoftGraphSetup.constants.sharedContainerIdentifier
		return try MicrosoftGraphCloudProvider(credential: credential, driveIdentifier: driveIdentifier, maxPageSize: maxPageSize, urlSessionConfiguration: configuration, unauthenticatedURLSessionConfiguration: unauthenticatedConfiguration)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		return try await fetchItemMetadata(for: item)
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		if let urlString = pageToken {
			return try await fetchItemList(forFolderAt: cloudPath, with: urlString)
		}
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		return try await fetchItemList(for: item)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let phases = Progress.phases(of: progress, 999)
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		let metadata = try await downloadFile(for: item, to: localURL)
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let attributes: [FileAttributeKey: Any]
		do {
			attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
		} catch CocoaError.fileReadNoSuchFile {
			throw CloudProviderError.itemNotFound
		}
		let localItemType = getItemType(from: attributes[FileAttributeKey.type] as? FileAttributeType)
		guard localItemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		guard let fileSize = attributes[FileAttributeKey.size] as? Int else {
			throw MicrosoftGraphError.missingFileSize
		}
		let phases = Progress.phases(of: progress, 999)
		do {
			let metadata = try await fetchItemMetadata(at: cloudPath)
			if !replaceExisting || (replaceExisting && metadata.itemType == .folder) {
				throw CloudProviderError.itemAlreadyExists
			}
		} catch CloudProviderError.itemNotFound {
			// no-op
		}
		let parentItem = try await resolveParentPath(forItemAt: cloudPath)
		let metadata = try await uploadFile(for: parentItem, from: localURL, to: cloudPath, fileSize: fileSize)
		phases.completeTransfer()
		return metadata
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		if try await checkForItemExistence(at: cloudPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let parentItem = try await resolveParentPath(forItemAt: cloudPath)
		try Task.checkCancellation()
		try await createFolder(for: parentItem, with: cloudPath.lastPathComponent)
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
		let item = try await resolvePath(forItemAt: cloudPath)
		try Task.checkCancellation()
		try await deleteItem(for: item)
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
		if try await checkForItemExistence(at: targetCloudPath) {
			throw CloudProviderError.itemAlreadyExists
		}
		let item = try await resolvePath(forItemAt: sourceCloudPath)
		let targetParentItem = try await resolveParentPath(forItemAt: targetCloudPath)
		try Task.checkCancellation()
		try await moveItem(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: MicrosoftGraphItem) async throws -> CloudItemMetadata {
		guard let url = URL(string: requestURLString(for: item)) else {
			throw MicrosoftGraphError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		let data = try await executeMSURLSessionDataTaskWithErrorMapping(with: request)
		try identifierCache.addOrUpdate(item)
		let driveItem = try MSGraphDriveItem(data: data)
		return try convertToCloudItemMetadata(driveItem, at: item.cloudPath)
	}

	private func fetchItemList(for item: MicrosoftGraphItem) async throws -> CloudItemList {
		guard item.itemType == .folder else {
			throw CloudProviderError.itemTypeMismatch
		}
		let request = try childrenRequest(for: item)
		return try await fetchItemList(forFolderAt: item.cloudPath, with: request)
	}

	private func fetchItemList(forFolderAt cloudPath: CloudPath, with urlString: String) async throws -> CloudItemList {
		guard let url = URL(string: urlString) else {
			throw CloudProviderError.pageTokenInvalid
		}
		let request = NSMutableURLRequest(url: url)
		do {
			return try await fetchItemList(forFolderAt: cloudPath, with: request)
		} catch {
			if let error = error as NSError? {
				if error.domain == NSURLErrorDomain, error.code == NSURLErrorUnsupportedURL {
					throw CloudProviderError.pageTokenInvalid
				}
			}
			throw error
		}
	}

	private func fetchItemList(forFolderAt cloudPath: CloudPath, with request: NSMutableURLRequest) async throws -> CloudItemList {
		let data = try await executeMSURLSessionDataTaskWithErrorMapping(with: request)
		let collection = try MSCollection(data: data)
		for case let item as [AnyHashable: Any] in collection.value {
			guard let driveItem = MSGraphDriveItem(dictionary: item) else {
				continue
			}
			guard let name = driveItem.name else {
				continue
			}
			let childCloudPath = cloudPath.appendingPathComponent(name)
			let childItem = MicrosoftGraphItem(cloudPath: childCloudPath, driveItem: driveItem)
			try identifierCache.addOrUpdate(childItem)
		}
		return try convertToCloudItemList(collection, at: cloudPath)
	}

	private func downloadFile(for item: MicrosoftGraphItem, to localURL: URL) async throws -> CloudItemMetadata {
		guard item.itemType == .file else {
			throw CloudProviderError.itemTypeMismatch
		}
		let request = try contentRequest(for: item)
		let remoteMetadata = try await fetchItemMetadata(for: item)
		try Task.checkCancellation()
		return try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			try await executeMSURLDownloadTask(with: request, to: stagedFile)
			return remoteMetadata
		})
	}

	private func uploadFile(for parentItem: MicrosoftGraphItem, from localURL: URL, to cloudPath: CloudPath, fileSize: Int) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		let uploadURL = try await createUploadSession(for: parentItem, with: cloudPath.lastPathComponent)
		let driveItem = try await uploadFileChunks(from: localURL, to: uploadURL, totalFileSize: fileSize)
		let item = MicrosoftGraphItem(cloudPath: cloudPath, driveItem: driveItem)
		try identifierCache.addOrUpdate(item)
		return try convertToCloudItemMetadata(driveItem, at: cloudPath)
	}

	private func createUploadSession(for parentItem: MicrosoftGraphItem, with filename: String) async throws -> URL {
		let request = try createUploadSessionRequest(for: parentItem, with: filename)
		let data = try await executeMSURLSessionDataTaskWithErrorMapping(with: request)
		let uploadSession = try MSGraphUploadSession(data: data)
		guard let uploadSessionURLString = uploadSession.uploadUrl, let uploadSessionURL = URL(string: uploadSessionURLString) else {
			throw MicrosoftGraphError.invalidURL
		}
		return uploadSessionURL
	}

	private func uploadFileChunks(from localURL: URL, to uploadURL: URL, totalFileSize: Int) async throws -> MSGraphDriveItem {
		var offset = 0
		while true {
			try Task.checkCancellation()
			let localFileChunkURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			defer {
				try? FileManager.default.removeItem(at: localFileChunkURL)
			}
			let chunkLength = try createFileChunk(at: localFileChunkURL, from: localURL, offset: offset, maxChunkLength: MicrosoftGraphCloudProvider.maxUploadFileChunkLength)
			let request = fileCunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: offset, totalLength: totalFileSize)
			let (data, response) = try await executeMSURLSessionUploadTask(with: request, localURL: localFileChunkURL)
			switch response.statusCode {
			case MSExpectedResponseCodes.accepted.rawValue:
				offset += chunkLength
			case MSExpectedResponseCodes.OK.rawValue, MSExpectedResponseCodes.created.rawValue:
				return try MSGraphDriveItem(data: data)
			default:
				throw mapStatusCodeToError(response.statusCode)
			}
		}
	}

	private func createFolder(for parentItem: MicrosoftGraphItem, with name: String) async throws {
		let request = try createFolderRequest(for: parentItem, with: name)
		let (data, response) = try await executeMSURLSessionDataTask(with: request)
		guard response.statusCode == MSExpectedResponseCodes.created.rawValue || response.statusCode == MSExpectedResponseCodes.OK.rawValue else {
			throw mapStatusCodeToError(response.statusCode)
		}
		let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
		let driveItem = try MSGraphDriveItem(data: data)
		let item = MicrosoftGraphItem(cloudPath: cloudPath, driveItem: driveItem)
		try identifierCache.addOrUpdate(item)
	}

	private func deleteItem(for item: MicrosoftGraphItem) async throws {
		let request = try deleteItemRequest(for: item)
		let response = try await executeMSURLSessionDataTaskWithoutData(with: request)
		guard response.statusCode == 204 else {
			throw mapStatusCodeToError(response.statusCode)
		}
		try identifierCache.invalidate(item)
	}

	private func moveItem(from sourceItem: MicrosoftGraphItem, toParent targetParentItem: MicrosoftGraphItem, targetCloudPath: CloudPath) async throws {
		let request = try moveItemRequest(for: sourceItem, with: targetParentItem, targetCloudPath: targetCloudPath)
		let data = try await executeMSURLSessionDataTaskWithErrorMapping(with: request)
		try identifierCache.invalidate(sourceItem)
		let driveItem = try MSGraphDriveItem(data: data)
		let targetItem = MicrosoftGraphItem(cloudPath: targetCloudPath, driveItem: driveItem)
		try identifierCache.addOrUpdate(targetItem)
	}

	// MARK: - Requests

	func requestURLString(for item: MicrosoftGraphItem) -> String {
		if let driveIdentifier = item.driveIdentifier ?? driveIdentifier {
			return "\(MSGraphBaseURL)/drives/\(driveIdentifier)/items/\(item.identifier)"
		} else {
			return "\(MSGraphBaseURL)/me/drive/items/\(item.identifier)"
		}
	}

	func childrenRequest(for item: MicrosoftGraphItem) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(requestURLString(for: item))/children?$top=\(maxPageSize)") else {
			throw MicrosoftGraphError.invalidURL
		}
		return NSMutableURLRequest(url: url)
	}

	func contentRequest(for item: MicrosoftGraphItem) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(requestURLString(for: item))/content") else {
			throw MicrosoftGraphError.invalidURL
		}
		return NSMutableURLRequest(url: url)
	}

	func createUploadSessionRequest(for parentItem: MicrosoftGraphItem, with name: String) throws -> NSMutableURLRequest {
		guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "\(requestURLString(for: parentItem)):/\(encodedName):/createUploadSession") else {
			throw MicrosoftGraphError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		request.httpMethod = HTTPMethodPost
		return request
	}

	func fileCunkUploadRequest(withUploadURL uploadURL: URL, chunkLength: Int, offset: Int, totalLength: Int) -> NSMutableURLRequest {
		let request = NSMutableURLRequest(url: uploadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60.0)
		request.httpMethod = HTTPMethodPut
		request.setValue(String(chunkLength), forHTTPHeaderField: "Content-Length")
		request.setValue("bytes \(offset)-\(offset + chunkLength - 1)/\(totalLength)", forHTTPHeaderField: "Content-Range")
		return request
	}

	func createFolderRequest(for parentItem: MicrosoftGraphItem, with name: String) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(requestURLString(for: parentItem))/children") else {
			throw MicrosoftGraphError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpMethod = HTTPMethodPost
		let newFolder = MSGraphDriveItem()
		newFolder.name = name
		newFolder.folder = MSGraphFolder()
		let newFolderData = try newFolder.getSerializedData()
		request.httpBody = newFolderData
		return request
	}

	func deleteItemRequest(for item: MicrosoftGraphItem) throws -> NSMutableURLRequest {
		guard let url = URL(string: requestURLString(for: item)) else {
			throw MicrosoftGraphError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		request.httpMethod = HTTPMethodDelete
		return request
	}

	func moveItemRequest(for item: MicrosoftGraphItem, with newParentItem: MicrosoftGraphItem, targetCloudPath: CloudPath) throws -> NSMutableURLRequest {
		guard let url = URL(string: requestURLString(for: item)) else {
			throw MicrosoftGraphError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpMethod = HTTPMethodPatch
		let updatedItem = MSGraphDriveItem()
		updatedItem.name = targetCloudPath.lastPathComponent
		let parentReference = MSGraphItemReference()
		parentReference.itemReferenceId = newParentItem.identifier
		parentReference.driveId = newParentItem.driveIdentifier
		updatedItem.parentReference = parentReference
		let updatedItemData: Data
		updatedItemData = try updatedItem.getSerializedData()
		request.httpBody = updatedItemData
		return request
	}

	// MARK: - Execution

	private func executeRawMSURLSessionDataTask(with request: NSMutableURLRequest) async throws -> (Data?, URLResponse?) {
		let urlRequest = request as URLRequest
		HTTPDebugLogger.logRequest(urlRequest)
		return try await withMainActorSDKContinuation { resumer in
			let task = MSURLSessionDataTask(request: (urlRequest as NSURLRequest).mutableCopy() as? NSMutableURLRequest, client: self.client) { data, response, error in
				if let response {
					HTTPDebugLogger.logResponse(response, with: data, or: nil)
				}
				if let error {
					resumer.resume(throwing: self.convertStandardError(error))
				} else {
					resumer.resume(returning: (data, response))
				}
			}
			task?.execute()
		}
	}

	private func executeMSURLSessionDataTask(with request: NSMutableURLRequest) async throws -> (Data, HTTPURLResponse) {
		let (data, response) = try await executeRawMSURLSessionDataTask(with: request)
		guard let data, let response = response as? HTTPURLResponse else {
			throw MicrosoftGraphError.unexpectedResult
		}
		return (data, response)
	}

	private func executeMSURLSessionDataTaskWithErrorMapping(with request: NSMutableURLRequest) async throws -> Data {
		let (data, httpResponse) = try await executeMSURLSessionDataTask(with: request)
		guard httpResponse.statusCode == MSExpectedResponseCodes.OK.rawValue else {
			throw mapStatusCodeToError(httpResponse.statusCode)
		}
		return data
	}

	private func executeMSURLSessionDataTaskWithoutData(with request: NSMutableURLRequest) async throws -> HTTPURLResponse {
		let (_, response) = try await executeRawMSURLSessionDataTask(with: request)
		guard let response = response as? HTTPURLResponse else {
			throw MicrosoftGraphError.unexpectedResult
		}
		return response
	}

	private func executeMSURLDownloadTask(with request: NSMutableURLRequest, to localURL: URL) async throws {
		let urlRequest = request as URLRequest
		HTTPDebugLogger.logRequest(urlRequest)
		try await withMainActorSDKContinuation { (resumer: Resumer<Void>) in
			let task = MSURLSessionDownloadTask(request: (urlRequest as NSURLRequest).mutableCopy() as? NSMutableURLRequest, client: self.client) { tempLocalURL, response, error in
				if let response {
					HTTPDebugLogger.logResponse(response, with: nil, or: tempLocalURL)
				}
				switch (tempLocalURL, response, error) {
				case let (.some(tempLocalURL), httpResponse as HTTPURLResponse, nil):
					guard httpResponse.statusCode == MSExpectedResponseCodes.OK.rawValue else {
						resumer.resume(throwing: self.mapStatusCodeToError(httpResponse.statusCode))
						return
					}
					do {
						try FileManager.default.moveItem(at: tempLocalURL, to: localURL)
						resumer.resume()
					} catch {
						resumer.resume(throwing: error)
					}
				case let (_, _, .some(error)):
					resumer.resume(throwing: self.convertStandardError(error))
				default:
					resumer.resume(throwing: MicrosoftGraphError.unexpectedResult)
				}
			}
			task?.execute()
		}
	}

	private func executeMSURLSessionUploadTask(with request: NSMutableURLRequest, localURL: URL) async throws -> (Data, HTTPURLResponse) {
		let urlRequest = request as URLRequest
		HTTPDebugLogger.logRequest(urlRequest)
		return try await withMainActorSDKContinuation { resumer in
			// We have to use an unauthenticated client, because the PUT request shouldn't contain an Authorization header.
			// https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0#remarks
			let task = MSURLSessionUploadTask(request: (urlRequest as NSURLRequest).mutableCopy() as? NSMutableURLRequest, fromFile: localURL, client: self.unauthenticatedClient) { data, response, error in
				if let response {
					HTTPDebugLogger.logResponse(response, with: data, or: nil)
				}
				switch (data, response, error) {
				case let (.some(data), httpResponse as HTTPURLResponse, nil):
					resumer.resume(returning: (data, httpResponse))
				case let (_, _, .some(error)):
					resumer.resume(throwing: self.convertStandardError(error))
				default:
					resumer.resume(throwing: MicrosoftGraphError.unexpectedResult)
				}
			}
			task?.execute()
		}
	}

	// MARK: - Resolve Path

	private func resolvePath(forItemAt cloudPath: CloudPath) async throws -> MicrosoftGraphItem {
		var pathToCheckForCache = cloudPath
		var cachedItem = identifierCache.get(pathToCheckForCache)
		while cachedItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
			pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
			cachedItem = identifierCache.get(pathToCheckForCache)
		}
		guard let item = cachedItem else {
			throw MicrosoftGraphError.inconsistentCache
		}
		if pathToCheckForCache != cloudPath {
			return try await traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: item)
		}
		return item
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) async throws -> MicrosoftGraphItem {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		do {
			return try await resolvePath(forItemAt: parentCloudPath)
		} catch CloudProviderError.itemNotFound {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}

	private func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: MicrosoftGraphItem) async throws -> MicrosoftGraphItem {
		assert(startCloudPath.pathComponents.count < endCloudPath.pathComponents.count)
		let startIndex = startCloudPath.pathComponents.count
		let endIndex = endCloudPath.pathComponents.count
		var parentItem = startItem
		for i in startIndex ..< endIndex {
			let itemName = endCloudPath.pathComponents[i]
			try Task.checkCancellation()
			parentItem = try await getMicrosoftGraphItem(for: itemName, withParentItem: parentItem)
			try identifierCache.addOrUpdate(parentItem)
		}
		return parentItem
	}

	private func getMicrosoftGraphItem(for name: String, withParentItem parentItem: MicrosoftGraphItem) async throws -> MicrosoftGraphItem {
		guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "\(requestURLString(for: parentItem)):/\(encodedName):") else {
			throw MicrosoftGraphError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		let data = try await executeMSURLSessionDataTaskWithErrorMapping(with: request)
		let driveItem = try MSGraphDriveItem(data: data)
		return MicrosoftGraphItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), driveItem: driveItem)
	}

	// MARK: - Helpers

	private func convertToCloudItemMetadata(_ driveItem: MSGraphDriveItem, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		guard let name = driveItem.name else {
			throw MicrosoftGraphError.missingItemName
		}
		let itemType = driveItem.getCloudItemType()
		let lastModifiedDate = driveItem.fileSystemInfo?.lastModifiedDateTime
		let size = Int(exactly: driveItem.size)
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
	}

	private func convertToCloudItemList(_ collection: MSCollection, at cloudPath: CloudPath) throws -> CloudItemList {
		var items = [CloudItemMetadata]()
		for case let item as [AnyHashable: Any] in collection.value {
			guard let driveItem = MSGraphDriveItem(dictionary: item) else {
				throw MicrosoftGraphError.unexpectedResult
			}
			guard let name = driveItem.name else {
				throw MicrosoftGraphError.missingItemName
			}
			let itemCloudPath = cloudPath.appendingPathComponent(name)
			let itemMetadata = try convertToCloudItemMetadata(driveItem, at: itemCloudPath)
			items.append(itemMetadata)
		}
		let nextPakeToken = collection.nextLink?.absoluteString ?? nil
		return CloudItemList(items: items, nextPageToken: nextPakeToken)
	}

	private func getItemType(from fileAttributeType: FileAttributeType?) -> CloudItemType {
		guard let type = fileAttributeType else {
			return CloudItemType.unknown
		}
		switch type {
		case .typeDirectory:
			return CloudItemType.folder
		case .typeRegular:
			return CloudItemType.file
		default:
			return CloudItemType.unknown
		}
	}

	private func mapStatusCodeToError(_ statusCode: Int) -> Error {
		switch statusCode {
		case MSClientErrorCode.MSClientErrorCodeUnauthorized.rawValue, MSClientErrorCode.MSClientErrorCodeForbidden.rawValue:
			return CloudProviderError.unauthorized
		case MSClientErrorCode.MSClientErrorCodeNotFound.rawValue:
			return CloudProviderError.itemNotFound
		case MSClientErrorCode.MSClientErrorCodeInsufficientStorage.rawValue:
			return CloudProviderError.quotaInsufficient
		default:
			return MicrosoftGraphError.unexpectedHTTPStatusCode(code: statusCode)
		}
	}

	func convertStandardError(_ error: Error) -> Error {
		if isCancellationError(error) {
			return CancellationError()
		}
		if isNetworkConnectionError(error) {
			return CloudProviderError.noInternetConnection
		}
		switch error {
		case MicrosoftGraphAuthenticationProviderError.accountNotFound:
			return CloudProviderError.unauthorized
		default:
			return error
		}
	}

	private func createFileChunk(at targetURL: URL, from sourceURL: URL, offset: Int, maxChunkLength: Int) throws -> Int {
		let bufferLength = 320 * 1024
		let inputFile = try FileHandle(forReadingFrom: sourceURL)
		inputFile.seek(toFileOffset: UInt64(offset))
		FileManager.default.createFile(atPath: targetURL.path, contents: nil, attributes: nil)
		let outputFile = try FileHandle(forWritingTo: targetURL)
		var readCount = 0
		var buffer: Data
		repeat {
			buffer = inputFile.readData(ofLength: bufferLength)
			outputFile.write(buffer)
			readCount += buffer.count
		} while !buffer.isEmpty && readCount + bufferLength <= maxChunkLength
		try outputFile.close()
		try inputFile.close()
		return readCount
	}
}
