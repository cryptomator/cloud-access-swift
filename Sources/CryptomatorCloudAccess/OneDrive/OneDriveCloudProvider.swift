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
	private let credential: OneDriveCredential
	private let client: MSHTTPClient
	private let identifierCache: OneDriveIdentifierCache
	private static let uploadFileChunkLength = 5 * 1024 * 1024 // 5MiB

	public init(credential: OneDriveCredential, useBackgroundSession: Bool = false) throws {
		self.credential = credential
		let urlSessionConfiguration = OneDriveCloudProvider.createURLSessionConfiguration(credential: credential, useBackgroundSession: useBackgroundSession)
		self.client = MSClientFactory.createHTTPClient(with: credential.authProvider, andSessionConfiguration: urlSessionConfiguration)
		self.identifierCache = try OneDriveIdentifierCache()
	}

	static func createURLSessionConfiguration(credential: OneDriveCredential, useBackgroundSession: Bool) -> URLSessionConfiguration {
		let configuration: URLSessionConfiguration
		if useBackgroundSession {
			let bundleId = Bundle.main.bundleIdentifier ?? ""
			configuration = URLSessionConfiguration.background(withIdentifier: "CloudAccess-OneDriveSession-\(credential.identifier)-\(bundleId)")
			configuration.sharedContainerIdentifier = OneDriveSetup.appGroupName
		} else {
			configuration = URLSessionConfiguration.default
		}
		return configuration
	}

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		return resolvePath(forItemAt: cloudPath).then(fetchItemMetadata)
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		if let pageToken = pageToken {
			return fetchItemList(forFolderAt: cloudPath, withPageToken: pageToken)
		}
		return resolvePath(forItemAt: cloudPath).then { oneDriveItem in
			return self.fetchItemList(for: oneDriveItem)
		}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		if FileManager.default.fileExists(atPath: localURL.path) {
			return Promise(CloudProviderError.itemAlreadyExists)
		}
		return resolvePath(forItemAt: cloudPath).then { oneDriveItem in
			self.downloadFile(oneDriveItem, to: localURL)
		}
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		precondition(!localURL.hasDirectoryPath)
		return resolveParentPath(forItemAt: cloudPath).then { _ in
			self.fetchItemMetadata(at: cloudPath)
		}.then { metadata -> Void in
			if replaceExisting {
				guard metadata.itemType == .file else {
					throw CloudProviderError.itemTypeMismatch
				}
			} else {
				throw CloudProviderError.itemAlreadyExists
			}
		}.recover { error -> Void in
			guard case CloudProviderError.itemNotFound = error else {
				throw error
			}
		}.then { _ -> Promise<OneDriveItem> in
			let parentPath = cloudPath.deletingLastPathComponent()
			return self.resolvePath(forItemAt: parentPath)
		}.then { oneDriveItem in
			self.uploadFile(from: localURL, to: oneDriveItem, withFilename: cloudPath.lastPathComponent)
		}.then { msGraphDriveItem in
			self.convertMSGraphDriveItemToCloudItemMetadata(msGraphDriveItem, cloudPath: cloudPath)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: cloudPath).then { itemExists -> Void in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then {
			self.resolveParentPath(forItemAt: cloudPath)
		}.then { parentOneDriveItem in
			return self.createFolder(withName: cloudPath.lastPathComponent, parentItem: parentOneDriveItem)
		}
	}

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath, itemType: .file)
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return deleteItem(at: cloudPath, itemType: .folder)
	}

	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	func fetchItemMetadata(for item: OneDriveItem) -> Promise<CloudItemMetadata> {
		guard let url = URL(string: requestURLString(for: item)) else {
			return Promise(OneDriveError.invalidURL)
		}
		let request = NSMutableURLRequest(url: url)
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> CloudItemMetadata in
			let driveItem = try MSGraphDriveItem(data: data)
			return self.convertMSGraphDriveItemToCloudItemMetadata(driveItem, cloudPath: item.path)
		}
	}

	func fetchItemList(for item: OneDriveItem) -> Promise<CloudItemList> {
		guard item.itemType == .folder else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		let request: NSMutableURLRequest
		do {
			request = try childrenRequest(for: item)
		} catch {
			return Promise(error)
		}
		return fetchItemList(forFolderAt: item.path, with: request)
	}

	func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String) -> Promise<CloudItemList> {
		guard let url = URL(string: pageToken) else {
			return Promise(OneDriveError.invalidURL)
		}
		let request = NSMutableURLRequest(url: url)
		return fetchItemList(forFolderAt: cloudPath, with: request)
	}

	func fetchItemList(forFolderAt cloudPath: CloudPath, with request: NSMutableURLRequest) -> Promise<CloudItemList> {
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> CloudItemList in
			let collection = try MSCollection(data: data)
			return try self.convertMSCollectionToCloudItemList(collection, folderPath: cloudPath)
		}
	}

	func downloadFile(_ item: OneDriveItem, to localURL: URL) -> Promise<Void> {
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

	func uploadFile(from localURL: URL, to parentItem: OneDriveItem, withFilename filename: String) -> Promise<MSGraphDriveItem> {
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
		return uploadLargeFile(from: localURL, filename: filename, totalFileSize: fileSize, toParentItem: parentItem)
	}

	func uploadLargeFile(from localURL: URL, filename: String, totalFileSize: Int, toParentItem parentItem: OneDriveItem) -> Promise<MSGraphDriveItem> {
		let cloudPath = parentItem.path.appendingPathComponent(filename)
		return createUploadSession(filename: filename, toParentItem: parentItem).then { url in
			self.uploadFileChunk(from: localURL, offset: 0, totalFileSize: totalFileSize, uploadURL: url, cloudPath: cloudPath)
		}
	}

	func createUploadSession(filename: String, toParentItem parentItem: OneDriveItem) -> Promise<URL> {
		let request: NSMutableURLRequest
		do {
			request = try createUploadSessionRequest(forFilename: filename, parentItem: parentItem)
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

	func uploadFileChunk(from localURL: URL, offset: Int, totalFileSize: Int, uploadURL: URL, cloudPath: CloudPath) -> Promise<MSGraphDriveItem> {
		guard let file = FileHandle(forReadingAtPath: localURL.path) else {
			return Promise(OneDriveError.invalidFilehandle)
		}
		file.seek(toFileOffset: UInt64(offset))
		let data = file.readData(ofLength: OneDriveCloudProvider.uploadFileChunkLength)
		let request = fileCunkUploadRequest(withUploadURL: uploadURL, chunkLength: data.count, offset: Int(offset), totalLength: totalFileSize)
		return executeMSURLSessionUploadTask(with: request, data: data).then { data, response in
			switch response.statusCode {
			case MSExpectedResponseCodes.accepted.rawValue:
				return self.uploadFileChunk(from: localURL, offset: offset + OneDriveCloudProvider.uploadFileChunkLength, totalFileSize: totalFileSize, uploadURL: uploadURL, cloudPath: cloudPath)
			case MSExpectedResponseCodes.OK.rawValue, MSExpectedResponseCodes.created.rawValue:
				let driveItem = try MSGraphDriveItem(data: data)
				return Promise(driveItem)
			default:
				return Promise(self.mapStatusCodeToError(response.statusCode))
			}
		}
	}

	func executeMSURLSessionUploadTask(with request: NSMutableURLRequest, data: Data) -> Promise<(Data, HTTPURLResponse)> {
		return Promise<(Data, HTTPURLResponse)> { fulfill, reject in
			let task = MSURLSessionUploadTask(request: request, data: data, client: self.client) { data, response, error in
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
			throw self.defaultErrorMapping(error)
		}
	}

	func fileCunkUploadRequest(withUploadURL uploadURL: URL, chunkLength: Int, offset: Int, totalLength: Int) -> NSMutableURLRequest {
		let request = NSMutableURLRequest(url: uploadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60.0)
		request.httpMethod = HTTPMethodPut
		request.setValue(String(chunkLength), forHTTPHeaderField: "Content-Length")
		request.setValue("bytes \(offset)-\(offset + chunkLength - 1)/\(totalLength)", forHTTPHeaderField: "Content-Range")
		return request
	}

	func createFolder(withName name: String, parentItem: OneDriveItem) -> Promise<Void> {
		let request: NSMutableURLRequest
		do {
			request = try createFolderRequest(for: name, in: parentItem)
		} catch {
			return Promise(error)
		}
		return executeMSURLSessionDataTask(with: request).then { data, response -> Void in
			guard response.statusCode == MSExpectedResponseCodes.created.rawValue || response.statusCode == MSExpectedResponseCodes.OK.rawValue else {
				throw self.mapStatusCodeToError(response.statusCode)
			}
			let driveItem = try MSGraphDriveItem(data: data)
			let itemPath = parentItem.path.appendingPathComponent(name)
			let oneDriveItem = OneDriveItem(path: itemPath, item: driveItem)
			try self.identifierCache.addOrUpdate(oneDriveItem)
		}.recover { error -> Void in
			if case CloudProviderError.itemNotFound = error {
				try self.identifierCache.remove(parentItem)
			}
			throw error
		}
	}

	func deleteItem(at cloudPath: CloudPath, itemType: CloudItemType) -> Promise<Void> {
		let resolvePathPromise = resolvePath(forItemAt: cloudPath)
		return resolvePathPromise.then(fetchItemMetadata).then { itemMetadata -> Promise<OneDriveItem> in
			guard itemMetadata.itemType == itemType else {
				throw CloudProviderError.itemTypeMismatch
			}
			return resolvePathPromise
		}.then { item in
			return self.deleteItem(item)
		}.then {
			resolvePathPromise
		}.recover { error -> Promise<OneDriveItem> in
			guard case CloudProviderError.itemNotFound = error else {
				throw error
			}
			return resolvePathPromise
		}.then { item in
			try self.identifierCache.remove(item)
		}
	}

	func deleteItem(_ item: OneDriveItem) -> Promise<Void> {
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
		}
	}

	func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: targetCloudPath).then { targetItemAlreadyExists in
			if targetItemAlreadyExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then { _ -> Promise<(OneDriveItem, OneDriveItem, OneDriveItem)> in
			return all(self.resolvePath(forItemAt: sourceCloudPath),
			           self.resolveParentPath(forItemAt: sourceCloudPath),
			           self.resolveParentPath(forItemAt: targetCloudPath))
		}.then { item, currentParentItem, newParentItem in
			self.moveItem(item, fromParentItem: currentParentItem, toParentItem: newParentItem, to: targetCloudPath)
		}
	}

	func moveItem(_ item: OneDriveItem, fromParentItem oldParentItem: OneDriveItem, toParentItem newParentItem: OneDriveItem, to targetCloudPath: CloudPath) -> Promise<Void> {
		let request: NSMutableURLRequest
		do {
			request = try moveItemRequest(for: item, newParentItem: newParentItem, targetCloudPath: targetCloudPath)
		} catch {
			return Promise(error)
		}
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> Void in
			try self.identifierCache.remove(item)
			let item = try MSGraphDriveItem(data: data)
			let oneDriveItem = OneDriveItem(path: targetCloudPath, item: item)
			try self.identifierCache.addOrUpdate(oneDriveItem)
		}
	}

	// MARK: MSURLSessionTask execution

	func executeRawMSURLSessionDataTask(with request: NSMutableURLRequest) -> Promise<(Data?, URLResponse?)> {
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
			throw self.defaultErrorMapping(error)
		}
	}

	func executeMSURLSessionDataTask(with request: NSMutableURLRequest) -> Promise<(Data, HTTPURLResponse)> {
		return executeRawMSURLSessionDataTask(with: request).then { data, response -> (Data, HTTPURLResponse) in
			guard let data = data, let response = response as? HTTPURLResponse else {
				throw OneDriveError.unexpectedResult
			}
			return (data, response)
		}
	}

	func executeMSURLSessionDataTaskWithErrorMapping(with request: NSMutableURLRequest) -> Promise<Data> {
		return executeMSURLSessionDataTask(with: request).then { data, httpResponse -> Data in
			guard httpResponse.statusCode == MSExpectedResponseCodes.OK.rawValue else {
				throw (self.mapStatusCodeToError(httpResponse.statusCode))
			}
			return data
		}
	}

	func executeMSURLSessionDataTaskWithoutData(with request: NSMutableURLRequest) -> Promise<HTTPURLResponse> {
		return executeRawMSURLSessionDataTask(with: request).then { _, response -> HTTPURLResponse in
			guard let response = response as? HTTPURLResponse else {
				throw OneDriveError.unexpectedResult
			}
			return response
		}
	}

	func executeMSURLDownloadTask(with request: NSMutableURLRequest, to localURL: URL) -> Promise<Void> {
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
			throw self.defaultErrorMapping(error)
		}
	}

	// MARK: Resolve Path

	func resolvePath(forItemAt cloudPath: CloudPath) -> Promise<OneDriveItem> {
		var pathToCheckForCache = cloudPath
		var cachedOneDriveItem = identifierCache.getCachedItem(for: pathToCheckForCache)
		while cachedOneDriveItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
			pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
			cachedOneDriveItem = identifierCache.getCachedItem(for: pathToCheckForCache)
		}
		guard let oneDriveItem = cachedOneDriveItem else {
			return Promise(OneDriveError.inconsistentCache)
		}
		if pathToCheckForCache != cloudPath {
			return traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: oneDriveItem)
		}
		return Promise(oneDriveItem)
	}

	func resolveParentPath(forItemAt cloudPath: CloudPath) -> Promise<OneDriveItem> {
		return resolvePath(forItemAt: cloudPath.deletingLastPathComponent()).recover { error -> OneDriveItem in
			if case CloudProviderError.itemNotFound = error {
				throw CloudProviderError.parentFolderDoesNotExist
			} else {
				throw error
			}
		}
	}

	func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: OneDriveItem) -> Promise<OneDriveItem> {
		let startIndex = startCloudPath.pathComponents.count
		let endIndex = endCloudPath.pathComponents.count
		var parentItem = startItem
		var currentPath = startCloudPath
		return Promise(on: .global()) { fulfill, _ in
			for i in startIndex ..< endIndex {
				let itemName = endCloudPath.pathComponents[i]
				currentPath = currentPath.appendingPathComponent(itemName)
				parentItem = try await(self.getOneDriveItem(for: itemName, withParentItem: parentItem))
				try self.identifierCache.addOrUpdate(parentItem)
			}
			fulfill(parentItem)
		}
	}

	func getOneDriveItem(for name: String, withParentItem parentItem: OneDriveItem) -> Promise<OneDriveItem> {
		guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "\(requestURLString(for: parentItem)):/\(encodedName)") else {
			return Promise(OneDriveError.invalidURL)
		}
		let request = NSMutableURLRequest(url: url)
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> OneDriveItem in
			let item = try MSGraphDriveItem(data: data)
			let oneDriveItem = OneDriveItem(path: parentItem.path.appendingPathComponent(name), item: item)
			return oneDriveItem
		}
	}

	// MARK: Requests

	func requestURLString(for item: OneDriveItem) -> String {
		if let driveIdentifier = item.driveIdentifier {
			return "\(MSGraphBaseURL)/drives/\(driveIdentifier)/items/\(item.itemIdentifier)"
		} else {
			return "\(MSGraphBaseURL)/me/drive/items/\(item.itemIdentifier)"
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

	func createUploadSessionRequest(forFilename filename: String, parentItem: OneDriveItem) throws -> NSMutableURLRequest {
		guard let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "\(requestURLString(for: parentItem)):/\(encodedName):/createUploadSession") else {
			throw OneDriveError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		request.httpMethod = HTTPMethodPost
		return request
	}

	func createFolderRequest(for foldername: String, in parentItem: OneDriveItem) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(requestURLString(for: parentItem))/children") else {
			throw OneDriveError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpMethod = HTTPMethodPost
		let newFolder = MSGraphDriveItem()
		newFolder.name = foldername
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

	func moveItemRequest(for item: OneDriveItem, newParentItem: OneDriveItem, targetCloudPath: CloudPath) throws -> NSMutableURLRequest {
		guard let url = URL(string: requestURLString(for: item)) else {
			throw OneDriveError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpMethod = HTTPMethodPatch
		let updatedItem = MSGraphDriveItem()
		updatedItem.name = targetCloudPath.lastPathComponent
		let parentReference = MSGraphItemReference()
		parentReference.itemReferenceId = newParentItem.itemIdentifier
		parentReference.driveId = newParentItem.driveIdentifier
		updatedItem.parentReference = parentReference
		let updatedItemData: Data
		updatedItemData = try updatedItem.getSerializedData()
		request.httpBody = updatedItemData
		return request
	}

	// MARK: Helper

	func convertMSCollectionToCloudItemList(_ collection: MSCollection, folderPath: CloudPath) throws -> CloudItemList {
		var items = [CloudItemMetadata]()
		for case let item as [AnyHashable: Any] in collection.value {
			guard let driveItem = MSGraphDriveItem(dictionary: item) else {
				throw OneDriveError.unexpectedResult
			}
			guard let name = driveItem.name else {
				throw OneDriveError.missingItemName
			}
			let itemPath = folderPath.appendingPathComponent(name)
			let itemMetdata = convertMSGraphDriveItemToCloudItemMetadata(driveItem, cloudPath: itemPath)
			let oneDriveItem = OneDriveItem(path: itemPath, item: driveItem)
			try identifierCache.addOrUpdate(oneDriveItem)
			items.append(itemMetdata)
		}
		if collection.nextLink == nil {
			return CloudItemList(items: items, nextPageToken: nil)
		}
		return CloudItemList(items: items, nextPageToken: collection.nextLink.absoluteString)
	}

	func convertMSGraphDriveItemToCloudItemMetadata(_ driveItem: MSGraphDriveItem, cloudPath: CloudPath) -> CloudItemMetadata {
		let lastModifiedDate = driveItem.fileSystemInfo?.lastModifiedDateTime
		let itemSize = Int(exactly: driveItem.size)
		let name: String
		if let driveItemName = driveItem.name {
			name = driveItemName
		} else {
			name = cloudPath.lastPathComponent
		}
		let itemMetadata = CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: driveItem.getCloudItemType(), lastModifiedDate: lastModifiedDate, size: itemSize)
		return itemMetadata
	}

	func mapStatusCodeToError(_ statusCode: Int) -> Error {
		switch statusCode {
		case MSClientErrorCode.MSClientErrorCodeNotFound.rawValue:
			return CloudProviderError.itemNotFound
		case MSClientErrorCode.MSClientErrorCodeInsufficientStorage.rawValue:
			return CloudProviderError.quotaInsufficient
		case MSClientErrorCode.MSClientErrorCodeUnauthorized.rawValue:
			return CloudProviderError.unauthorized
		case MSClientErrorCode.MSClientErrorCodeInsufficientStorage.rawValue:
			return CloudProviderError.quotaInsufficient
		default:
			return OneDriveError.unexpectedHTTPStatusCode(code: statusCode)
		}
	}

	func getItemType(from fileAttributeType: FileAttributeType?) -> CloudItemType {
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

	func defaultErrorMapping(_ error: Error) -> Error {
		switch error {
		case OneDriveAuthenticationProviderError.accountNotFound, OneDriveAuthenticationProviderError.noAccounts:
			return CloudProviderError.unauthorized
		default:
			return error
		}
	}
}
