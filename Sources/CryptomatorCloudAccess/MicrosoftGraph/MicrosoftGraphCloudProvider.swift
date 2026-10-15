//
//  MicrosoftGraphCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

public final class MicrosoftGraphCloudProvider: CloudProvider {
	private static let maxUploadFileChunkLength = 16 * 320 * 1024 // 5MiB

	private let client: MicrosoftGraphHTTPClient
	private let driveIdentifier: String?
	private let identifierCache: MicrosoftGraphIdentifierCache
	private let tmpDirURL: URL
	private let maxPageSize: Int

	init(credential: MicrosoftGraphCredential, driveIdentifier: String? = nil, maxPageSize: Int = .max, urlSessionConfiguration: URLSessionConfiguration) throws {
		self.client = MicrosoftGraphHTTPClient(accessTokenProvider: credential.accessTokenProvider, configuration: urlSessionConfiguration)
		self.driveIdentifier = driveIdentifier
		self.identifierCache = try MicrosoftGraphIdentifierCache()
		self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		self.maxPageSize = min(max(1, maxPageSize), 1000)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	public convenience init(credential: MicrosoftGraphCredential, driveIdentifier: String? = nil, maxPageSize: Int = .max) throws {
		try self.init(credential: credential, driveIdentifier: driveIdentifier, maxPageSize: maxPageSize, urlSessionConfiguration: .default)
	}

	public static func withBackgroundSession(credential: MicrosoftGraphCredential, driveIdentifier: String? = nil, maxPageSize: Int = .max, sessionIdentifier: String) throws -> MicrosoftGraphCloudProvider {
		let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
		configuration.sharedContainerIdentifier = MicrosoftGraphSetup.constants.sharedContainerIdentifier
		return try MicrosoftGraphCloudProvider(credential: credential, driveIdentifier: driveIdentifier, maxPageSize: maxPageSize, urlSessionConfiguration: configuration)
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
		let data = try await sendExpectingOK(URLRequest(url: url))
		try identifierCache.addOrUpdate(item)
		let driveItem = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: data)
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
		do {
			return try await fetchItemList(forFolderAt: cloudPath, with: URLRequest(url: url))
		} catch {
			if let error = error as NSError? {
				if error.domain == NSURLErrorDomain, error.code == NSURLErrorUnsupportedURL {
					throw CloudProviderError.pageTokenInvalid
				}
			}
			throw error
		}
	}

	private func fetchItemList(forFolderAt cloudPath: CloudPath, with request: URLRequest) async throws -> CloudItemList {
		let data = try await sendExpectingOK(request)
		let collection = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.DriveItem>.self, from: data)
		for driveItem in collection.value {
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
			try await download(request, to: stagedFile)
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
		let data = try await sendExpectingOK(request)
		let uploadSession = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.UploadSession.self, from: data)
		guard let uploadSessionURLString = uploadSession.uploadUrl, let uploadSessionURL = URL(string: uploadSessionURLString) else {
			throw MicrosoftGraphError.invalidURL
		}
		return uploadSessionURL
	}

	private func uploadFileChunks(from localURL: URL, to uploadURL: URL, totalFileSize: Int) async throws -> MicrosoftGraphAPI.DriveItem {
		var offset = 0
		while true {
			try Task.checkCancellation()
			let localFileChunkURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			defer {
				try? FileManager.default.removeItem(at: localFileChunkURL)
			}
			let chunkLength = try createFileChunk(at: localFileChunkURL, from: localURL, offset: offset, maxChunkLength: MicrosoftGraphCloudProvider.maxUploadFileChunkLength)
			let request = fileChunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: offset, totalLength: totalFileSize)
			let (response, data) = try await upload(request, fromFile: localFileChunkURL)
			switch response.statusCode {
			case 202:
				offset += chunkLength
			case 200, 201:
				return try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: data)
			default:
				throw mapStatusCodeToError(response.statusCode)
			}
		}
	}

	private func createFolder(for parentItem: MicrosoftGraphItem, with name: String) async throws {
		let request = try createFolderRequest(for: parentItem, with: name)
		let (response, data) = try await send(request)
		guard response.statusCode == 201 || response.statusCode == 200 else {
			throw mapStatusCodeToError(response.statusCode)
		}
		let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
		let driveItem = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: data)
		let item = MicrosoftGraphItem(cloudPath: cloudPath, driveItem: driveItem)
		try identifierCache.addOrUpdate(item)
	}

	private func deleteItem(for item: MicrosoftGraphItem) async throws {
		let request = try deleteItemRequest(for: item)
		let (response, _) = try await send(request)
		guard response.statusCode == 204 else {
			throw mapStatusCodeToError(response.statusCode)
		}
		try identifierCache.invalidate(item)
	}

	private func moveItem(from sourceItem: MicrosoftGraphItem, toParent targetParentItem: MicrosoftGraphItem, targetCloudPath: CloudPath) async throws {
		let request = try moveItemRequest(for: sourceItem, with: targetParentItem, targetCloudPath: targetCloudPath)
		let data = try await sendExpectingOK(request)
		try identifierCache.invalidate(sourceItem)
		let driveItem = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: data)
		let targetItem = MicrosoftGraphItem(cloudPath: targetCloudPath, driveItem: driveItem)
		try identifierCache.addOrUpdate(targetItem)
	}

	// MARK: - Requests

	func requestURLString(for item: MicrosoftGraphItem) -> String {
		if let driveIdentifier = item.driveIdentifier ?? driveIdentifier {
			return "\(MicrosoftGraphAPI.baseURL)/drives/\(driveIdentifier)/items/\(item.identifier)"
		} else {
			return "\(MicrosoftGraphAPI.baseURL)/me/drive/items/\(item.identifier)"
		}
	}

	func childrenRequest(for item: MicrosoftGraphItem) throws -> URLRequest {
		guard let url = URL(string: "\(requestURLString(for: item))/children?$top=\(maxPageSize)") else {
			throw MicrosoftGraphError.invalidURL
		}
		return URLRequest(url: url)
	}

	func contentRequest(for item: MicrosoftGraphItem) throws -> URLRequest {
		guard let url = URL(string: "\(requestURLString(for: item))/content") else {
			throw MicrosoftGraphError.invalidURL
		}
		return URLRequest(url: url)
	}

	func createUploadSessionRequest(for parentItem: MicrosoftGraphItem, with name: String) throws -> URLRequest {
		guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "\(requestURLString(for: parentItem)):/\(encodedName):/createUploadSession") else {
			throw MicrosoftGraphError.invalidURL
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		return request
	}

	func fileChunkUploadRequest(withUploadURL uploadURL: URL, chunkLength: Int, offset: Int, totalLength: Int) -> URLRequest {
		var request = URLRequest(url: uploadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60.0)
		request.httpMethod = "PUT"
		request.setValue(String(chunkLength), forHTTPHeaderField: "Content-Length")
		request.setValue("bytes \(offset)-\(offset + chunkLength - 1)/\(totalLength)", forHTTPHeaderField: "Content-Range")
		return request
	}

	func createFolderRequest(for parentItem: MicrosoftGraphItem, with name: String) throws -> URLRequest {
		guard let url = URL(string: "\(requestURLString(for: parentItem))/children") else {
			throw MicrosoftGraphError.invalidURL
		}
		var request = URLRequest(url: url)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpMethod = "POST"
		request.httpBody = try MicrosoftGraphAPI.encode(MicrosoftGraphAPI.DriveItemRequestBody(name: name, folder: MicrosoftGraphAPI.Folder()))
		return request
	}

	func deleteItemRequest(for item: MicrosoftGraphItem) throws -> URLRequest {
		guard let url = URL(string: requestURLString(for: item)) else {
			throw MicrosoftGraphError.invalidURL
		}
		var request = URLRequest(url: url)
		request.httpMethod = "DELETE"
		return request
	}

	func moveItemRequest(for item: MicrosoftGraphItem, with newParentItem: MicrosoftGraphItem, targetCloudPath: CloudPath) throws -> URLRequest {
		guard let url = URL(string: requestURLString(for: item)) else {
			throw MicrosoftGraphError.invalidURL
		}
		var request = URLRequest(url: url)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpMethod = "PATCH"
		let parentReference = MicrosoftGraphAPI.ItemReference(id: newParentItem.identifier, driveId: newParentItem.driveIdentifier)
		request.httpBody = try MicrosoftGraphAPI.encode(MicrosoftGraphAPI.DriveItemRequestBody(name: targetCloudPath.lastPathComponent, parentReference: parentReference))
		return request
	}

	// MARK: - Execution

	private func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
		do {
			return try await client.data(for: request)
		} catch {
			throw convertStandardError(error)
		}
	}

	private func sendExpectingOK(_ request: URLRequest) async throws -> Data {
		let (response, data) = try await send(request)
		guard response.statusCode == 200 else {
			throw mapStatusCodeToError(response.statusCode)
		}
		return data
	}

	private func download(_ request: URLRequest, to localURL: URL) async throws {
		let response: HTTPURLResponse
		do {
			response = try await client.download(request, to: localURL)
		} catch {
			throw convertStandardError(error)
		}
		guard response.statusCode == 200 else {
			throw mapStatusCodeToError(response.statusCode)
		}
	}

	private func upload(_ request: URLRequest, fromFile localURL: URL) async throws -> (HTTPURLResponse, Data) {
		do {
			return try await client.upload(request, fromFile: localURL)
		} catch {
			throw convertStandardError(error)
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
		let data = try await sendExpectingOK(URLRequest(url: url))
		let driveItem = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: data)
		return MicrosoftGraphItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), driveItem: driveItem)
	}

	// MARK: - Helpers

	private func convertToCloudItemMetadata(_ driveItem: MicrosoftGraphAPI.DriveItem, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		guard let name = driveItem.name else {
			throw MicrosoftGraphError.missingItemName
		}
		let itemType = driveItem.cloudItemType
		let lastModifiedDate = driveItem.fileSystemInfo?.lastModifiedDate
		let size = Int(driveItem.size ?? 0)
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
	}

	private func convertToCloudItemList(_ collection: MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.DriveItem>, at cloudPath: CloudPath) throws -> CloudItemList {
		var items = [CloudItemMetadata]()
		for driveItem in collection.value {
			guard let name = driveItem.name else {
				throw MicrosoftGraphError.missingItemName
			}
			let itemCloudPath = cloudPath.appendingPathComponent(name)
			let itemMetadata = try convertToCloudItemMetadata(driveItem, at: itemCloudPath)
			items.append(itemMetadata)
		}
		return CloudItemList(items: items, nextPageToken: collection.nextLink)
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
		case 401, 403:
			return CloudProviderError.unauthorized
		case 404:
			return CloudProviderError.itemNotFound
		case 507:
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
		return error
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
