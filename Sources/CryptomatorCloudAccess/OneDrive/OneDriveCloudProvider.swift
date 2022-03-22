//
//  OneDriveCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import MSGraphClientModels
import MSGraphClientSDK
import Promises

public class OneDriveCloudProvider: CloudProvider {
	private static let maxUploadFileChunkLength = 16 * 320 * 1024 // 5MiB

	private let client: MSHTTPClient
	private let identifierCache: OneDriveIdentifierCache
	private let tmpDirURL: URL

	public init(credential: OneDriveCredential, useBackgroundSession: Bool = false) throws {
		let urlSessionConfiguration = OneDriveCloudProvider.createURLSessionConfiguration(credential: credential, useBackgroundSession: useBackgroundSession)
		self.client = MSClientFactory.createHTTPClient(with: credential.authProvider, andSessionConfiguration: urlSessionConfiguration)
		self.identifierCache = try OneDriveIdentifierCache()
		self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	deinit {
		try? FileManager.default.removeItem(at: tmpDirURL)
	}

	static func createURLSessionConfiguration(credential: OneDriveCredential, useBackgroundSession: Bool) -> URLSessionConfiguration {
		let configuration: URLSessionConfiguration
		if useBackgroundSession {
			let bundleId = Bundle.main.bundleIdentifier ?? ""
			configuration = URLSessionConfiguration.background(withIdentifier: "CloudAccess-OneDriveSession-\(credential.identifier)-\(bundleId)")
			configuration.sharedContainerIdentifier = OneDriveSetup.sharedContainerIdentifier
		} else {
			configuration = URLSessionConfiguration.default
		}
		return configuration
	}

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		return resolvePath(forItemAt: cloudPath).then { item in
			return self.fetchItemMetadata(for: item)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		if let urlString = pageToken {
			return fetchItemList(forFolderAt: cloudPath, with: urlString)
		}
		return resolvePath(forItemAt: cloudPath).then { item in
			return self.fetchItemList(for: item)
		}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		if FileManager.default.fileExists(atPath: localURL.path) {
			return Promise(CloudProviderError.itemAlreadyExists)
		}
		return resolvePath(forItemAt: cloudPath).then { item in
			self.downloadFile(for: item, to: localURL)
		}
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		let attributes: [FileAttributeKey: Any]
		do {
			attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
		} catch CocoaError.fileReadNoSuchFile {
			return Promise(CloudProviderError.itemNotFound)
		} catch {
			return Promise(error)
		}
		let localItemType = getItemType(from: attributes[FileAttributeKey.type] as? FileAttributeType)
		guard localItemType == .file else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		guard let fileSize = attributes[FileAttributeKey.size] as? Int else {
			return Promise(OneDriveError.missingFileSize)
		}
		return fetchItemMetadata(at: cloudPath).then { metadata -> Void in
			if !replaceExisting || (replaceExisting && metadata.itemType == .folder) {
				throw CloudProviderError.itemAlreadyExists
			}
		}.recover { error -> Void in
			guard case CloudProviderError.itemNotFound = error else {
				throw error
			}
		}.then { _ -> Promise<OneDriveItem> in
			return self.resolveParentPath(forItemAt: cloudPath)
		}.then { item in
			return self.uploadFile(for: item, from: localURL, to: cloudPath, fileSize: fileSize)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: cloudPath).then { itemExists -> Void in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then {
			self.resolveParentPath(forItemAt: cloudPath)
		}.then { parentItem in
			return self.createFolder(for: parentItem, with: cloudPath.lastPathComponent)
		}
	}

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath)
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath)
	}

	private func deleteItem(at cloudPath: CloudPath) -> Promise<Void> {
		return resolvePath(forItemAt: cloudPath).then { item in
			return self.deleteItem(for: item)
		}
	}

	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: targetCloudPath).then { itemExists in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then { _ -> Promise<(OneDriveItem, OneDriveItem)> in
			return all(self.resolvePath(forItemAt: sourceCloudPath), self.resolveParentPath(forItemAt: targetCloudPath))
		}.then { item, targetParentItem in
			self.moveItem(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
		}
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: OneDriveItem) -> Promise<CloudItemMetadata> {
		guard let url = URL(string: requestURLString(for: item)) else {
			return Promise(OneDriveError.invalidURL)
		}
		let request = NSMutableURLRequest(url: url)
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> CloudItemMetadata in
			try self.identifierCache.addOrUpdate(item)
			let driveItem = try MSGraphDriveItem(data: data)
			return try self.convertToCloudItemMetadata(driveItem, at: item.cloudPath)
		}
	}

	private func fetchItemList(for item: OneDriveItem) -> Promise<CloudItemList> {
		guard item.itemType == .folder else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		let request: NSMutableURLRequest
		do {
			request = try childrenRequest(for: item)
		} catch {
			return Promise(error)
		}
		return fetchItemList(forFolderAt: item.cloudPath, with: request)
	}

	private func fetchItemList(forFolderAt cloudPath: CloudPath, with urlString: String) -> Promise<CloudItemList> {
		guard let url = URL(string: urlString) else {
			return Promise(CloudProviderError.pageTokenInvalid)
		}
		let request = NSMutableURLRequest(url: url)
		return fetchItemList(forFolderAt: cloudPath, with: request).recover { error -> CloudItemList in
			if let error = error as NSError? {
				if error.domain == NSURLErrorDomain, error.code == NSURLErrorUnsupportedURL {
					throw CloudProviderError.pageTokenInvalid
				}
			}
			throw error
		}
	}

	private func fetchItemList(forFolderAt cloudPath: CloudPath, with request: NSMutableURLRequest) -> Promise<CloudItemList> {
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> CloudItemList in
			let collection = try MSCollection(data: data)
			for case let item as [AnyHashable: Any] in collection.value {
				guard let driveItem = MSGraphDriveItem(dictionary: item) else {
					continue
				}
				guard let name = driveItem.name else {
					continue
				}
				let childCloudPath = cloudPath.appendingPathComponent(name)
				let childItem = OneDriveItem(cloudPath: childCloudPath, driveItem: driveItem)
				try self.identifierCache.addOrUpdate(childItem)
			}
			return try self.convertToCloudItemList(collection, at: cloudPath)
		}
	}

	private func downloadFile(for item: OneDriveItem, to localURL: URL) -> Promise<Void> {
		guard item.itemType == .file else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		let request: NSMutableURLRequest
		do {
			request = try contentRequest(for: item)
		} catch {
			return Promise(error)
		}
		return executeMSURLDownloadTask(with: request, to: localURL)
	}

	private func uploadFile(for parentItem: OneDriveItem, from localURL: URL, to cloudPath: CloudPath, fileSize: Int) -> Promise<CloudItemMetadata> {
		return createUploadSession(for: parentItem, with: cloudPath.lastPathComponent).then { uploadURL in
			self.uploadFileChunk(from: localURL, to: uploadURL, offset: 0, totalFileSize: fileSize)
		}.then { driveItem -> CloudItemMetadata in
			let item = OneDriveItem(cloudPath: cloudPath, driveItem: driveItem)
			try self.identifierCache.addOrUpdate(item)
			return try self.convertToCloudItemMetadata(driveItem, at: cloudPath)
		}
	}

	private func createUploadSession(for parentItem: OneDriveItem, with filename: String) -> Promise<URL> {
		let request: NSMutableURLRequest
		do {
			request = try createUploadSessionRequest(for: parentItem, with: filename)
		} catch {
			return Promise(error)
		}
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> URL in
			let uploadSession = try MSGraphUploadSession(data: data)
			guard let uploadSessionURLString = uploadSession.uploadUrl, let uploadSessionURL = URL(string: uploadSessionURLString) else {
				throw OneDriveError.invalidURL
			}
			return uploadSessionURL
		}
	}

	private func uploadFileChunk(from localURL: URL, to uploadURL: URL, offset: Int, totalFileSize: Int) -> Promise<MSGraphDriveItem> {
		let localFileChunkURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let chunkLength: Int
		do {
			chunkLength = try createFileChunk(at: localFileChunkURL, from: localURL, offset: offset, maxChunkLength: OneDriveCloudProvider.maxUploadFileChunkLength)
		} catch {
			return Promise(error)
		}
		let request = fileCunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: Int(offset), totalLength: totalFileSize)
		return executeMSURLSessionUploadTask(with: request, localURL: localFileChunkURL).then { data, response in
			switch response.statusCode {
			case MSExpectedResponseCodes.accepted.rawValue:
				return self.uploadFileChunk(from: localURL, to: uploadURL, offset: offset + chunkLength, totalFileSize: totalFileSize)
			case MSExpectedResponseCodes.OK.rawValue, MSExpectedResponseCodes.created.rawValue:
				let driveItem = try MSGraphDriveItem(data: data)
				return Promise(driveItem)
			default:
				return Promise(self.mapStatusCodeToError(response.statusCode))
			}
		}.always {
			try? FileManager.default.removeItem(at: localFileChunkURL)
		}
	}

	private func createFolder(for parentItem: OneDriveItem, with name: String) -> Promise<Void> {
		let request: NSMutableURLRequest
		do {
			request = try createFolderRequest(for: parentItem, with: name)
		} catch {
			return Promise(error)
		}
		return executeMSURLSessionDataTask(with: request).then { data, response -> Void in
			guard response.statusCode == MSExpectedResponseCodes.created.rawValue || response.statusCode == MSExpectedResponseCodes.OK.rawValue else {
				throw self.mapStatusCodeToError(response.statusCode)
			}
			let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
			let driveItem = try MSGraphDriveItem(data: data)
			let item = OneDriveItem(cloudPath: cloudPath, driveItem: driveItem)
			try self.identifierCache.addOrUpdate(item)
		}
	}

	private func deleteItem(for item: OneDriveItem) -> Promise<Void> {
		let request: NSMutableURLRequest
		do {
			request = try deleteItemRequest(for: item)
		} catch {
			return Promise(error)
		}
		return executeMSURLSessionDataTaskWithoutData(with: request).then { response -> Void in
			guard response.statusCode == 204 else {
				throw self.mapStatusCodeToError(response.statusCode)
			}
			try self.identifierCache.invalidate(item)
		}
	}

	private func moveItem(from sourceItem: OneDriveItem, toParent targetParentItem: OneDriveItem, targetCloudPath: CloudPath) -> Promise<Void> {
		let request: NSMutableURLRequest
		do {
			request = try moveItemRequest(for: sourceItem, with: targetParentItem, targetCloudPath: targetCloudPath)
		} catch {
			return Promise(error)
		}
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> Void in
			try self.identifierCache.invalidate(sourceItem)
			let driveItem = try MSGraphDriveItem(data: data)
			let targetItem = OneDriveItem(cloudPath: targetCloudPath, driveItem: driveItem)
			try self.identifierCache.addOrUpdate(targetItem)
		}
	}

	// MARK: - Requests

	func requestURLString(for item: OneDriveItem) -> String {
		if let driveIdentifier = item.driveIdentifier {
			return "\(MSGraphBaseURL)/drives/\(driveIdentifier)/items/\(item.identifier)"
		} else {
			return "\(MSGraphBaseURL)/me/drive/items/\(item.identifier)"
		}
	}

	func childrenRequest(for item: OneDriveItem) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(requestURLString(for: item))/children") else {
			throw OneDriveError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		return request
	}

	func contentRequest(for item: OneDriveItem) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(requestURLString(for: item))/content") else {
			throw OneDriveError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		return request
	}

	func createUploadSessionRequest(for parentItem: OneDriveItem, with name: String) throws -> NSMutableURLRequest {
		guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "\(requestURLString(for: parentItem)):/\(encodedName):/createUploadSession") else {
			throw OneDriveError.invalidURL
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

	func createFolderRequest(for parentItem: OneDriveItem, with name: String) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(requestURLString(for: parentItem))/children") else {
			throw OneDriveError.invalidURL
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

	func deleteItemRequest(for item: OneDriveItem) throws -> NSMutableURLRequest {
		guard let url = URL(string: requestURLString(for: item)) else {
			throw OneDriveError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		request.httpMethod = HTTPMethodDelete
		return request
	}

	func moveItemRequest(for item: OneDriveItem, with newParentItem: OneDriveItem, targetCloudPath: CloudPath) throws -> NSMutableURLRequest {
		guard let url = URL(string: requestURLString(for: item)) else {
			throw OneDriveError.invalidURL
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

	private func executeRawMSURLSessionDataTask(with request: NSMutableURLRequest) -> Promise<(Data?, URLResponse?)> {
		return Promise<(Data?, URLResponse?)> { fulfill, reject in
			let task = MSURLSessionDataTask(request: request, client: self.client) { data, response, error in
				if let error = error {
					reject(error)
				} else {
					fulfill((data, response))
				}
			}
			task?.execute()
		}.recover { error -> (Data?, URLResponse?) in
			throw self.convertStandardError(error)
		}
	}

	private func executeMSURLSessionDataTask(with request: NSMutableURLRequest) -> Promise<(Data, HTTPURLResponse)> {
		return executeRawMSURLSessionDataTask(with: request).then { data, response -> (Data, HTTPURLResponse) in
			guard let data = data, let response = response as? HTTPURLResponse else {
				throw OneDriveError.unexpectedResult
			}
			return (data, response)
		}
	}

	private func executeMSURLSessionDataTaskWithErrorMapping(with request: NSMutableURLRequest) -> Promise<Data> {
		return executeMSURLSessionDataTask(with: request).then { data, httpResponse -> Data in
			guard httpResponse.statusCode == MSExpectedResponseCodes.OK.rawValue else {
				throw (self.mapStatusCodeToError(httpResponse.statusCode))
			}
			return data
		}
	}

	private func executeMSURLSessionDataTaskWithoutData(with request: NSMutableURLRequest) -> Promise<HTTPURLResponse> {
		return executeRawMSURLSessionDataTask(with: request).then { _, response -> HTTPURLResponse in
			guard let response = response as? HTTPURLResponse else {
				throw OneDriveError.unexpectedResult
			}
			return response
		}
	}

	private func executeMSURLDownloadTask(with request: NSMutableURLRequest, to localURL: URL) -> Promise<Void> {
		return Promise<Void> { fulfill, reject in
			let task = MSURLSessionDownloadTask(request: request, client: self.client) { tempLocalURL, response, error in
				switch (tempLocalURL, response, error) {
				case let (.some(tempLocalURL), httpResponse as HTTPURLResponse, nil):
					guard httpResponse.statusCode == MSExpectedResponseCodes.OK.rawValue else {
						reject(self.mapStatusCodeToError(httpResponse.statusCode))
						return
					}
					do {
						try FileManager.default.moveItem(at: tempLocalURL, to: localURL)
						fulfill(())
					} catch {
						reject(error)
					}
				case let (_, _, .some(error)):
					reject(error)
				default:
					reject(OneDriveError.unexpectedResult)
				}
			}
			task?.execute()
		}.recover { error -> Void in
			throw self.convertStandardError(error)
		}
	}

	private func executeMSURLSessionUploadTask(with request: NSMutableURLRequest, localURL: URL) -> Promise<(Data, HTTPURLResponse)> {
		return Promise<(Data, HTTPURLResponse)> { fulfill, reject in
			let task = MSURLSessionUploadTask(request: request, fromFile: localURL, client: self.client) { data, response, error in
				switch (data, response, error) {
				case let (.some(data), httpResponse as HTTPURLResponse, nil):
					fulfill((data, httpResponse))
				case let (_, _, .some(error)):
					reject(error)
				default:
					reject(OneDriveError.unexpectedResult)
				}
			}
			task?.execute()
		}.recover { error -> (Data, HTTPURLResponse) in
			throw self.convertStandardError(error)
		}
	}

	// MARK: - Resolve Path

	private func resolvePath(forItemAt cloudPath: CloudPath) -> Promise<OneDriveItem> {
		var pathToCheckForCache = cloudPath
		var cachedItem = identifierCache.get(pathToCheckForCache)
		while cachedItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
			pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
			cachedItem = identifierCache.get(pathToCheckForCache)
		}
		guard let item = cachedItem else {
			return Promise(OneDriveError.inconsistentCache)
		}
		if pathToCheckForCache != cloudPath {
			return traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: item)
		}
		return Promise(item)
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) -> Promise<OneDriveItem> {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		return resolvePath(forItemAt: parentCloudPath).recover { error -> OneDriveItem in
			if case CloudProviderError.itemNotFound = error {
				throw CloudProviderError.parentFolderDoesNotExist
			} else {
				throw error
			}
		}
	}

	private func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: OneDriveItem) -> Promise<OneDriveItem> {
		assert(startCloudPath.pathComponents.count < endCloudPath.pathComponents.count)
		let startIndex = startCloudPath.pathComponents.count
		let endIndex = endCloudPath.pathComponents.count
		var currentPath = startCloudPath
		var parentItem = startItem
		return Promise(on: .global()) { fulfill, _ in
			for i in startIndex ..< endIndex {
				let itemName = endCloudPath.pathComponents[i]
				currentPath = currentPath.appendingPathComponent(itemName)
				parentItem = try awaitPromise(self.getOneDriveItem(for: itemName, withParentItem: parentItem))
				try self.identifierCache.addOrUpdate(parentItem)
			}
			fulfill(parentItem)
		}
	}

	private func getOneDriveItem(for name: String, withParentItem parentItem: OneDriveItem) -> Promise<OneDriveItem> {
		guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "\(requestURLString(for: parentItem)):/\(encodedName):") else {
			return Promise(OneDriveError.invalidURL)
		}
		let request = NSMutableURLRequest(url: url)
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> OneDriveItem in
			let driveItem = try MSGraphDriveItem(data: data)
			return OneDriveItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), driveItem: driveItem)
		}
	}

	// MARK: - Helpers

	private func convertToCloudItemMetadata(_ driveItem: MSGraphDriveItem, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		guard let name = driveItem.name else {
			throw OneDriveError.missingItemName
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
				throw OneDriveError.unexpectedResult
			}
			guard let name = driveItem.name else {
				throw OneDriveError.missingItemName
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
		case MSClientErrorCode.MSClientErrorCodeNotFound.rawValue:
			return CloudProviderError.itemNotFound
		case MSClientErrorCode.MSClientErrorCodeUnauthorized.rawValue:
			return CloudProviderError.unauthorized
		case MSClientErrorCode.MSClientErrorCodeInsufficientStorage.rawValue:
			return CloudProviderError.quotaInsufficient
		default:
			return OneDriveError.unexpectedHTTPStatusCode(code: statusCode)
		}
	}

	private func convertStandardError(_ error: Error) -> Error {
		switch error {
		case OneDriveAuthenticationProviderError.accountNotFound, OneDriveAuthenticationProviderError.noAccounts:
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
