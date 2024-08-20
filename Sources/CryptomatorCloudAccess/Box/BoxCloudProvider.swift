//
//  BoxCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import BoxSdkGen
import CryptoKit
import Foundation
import Promises

public class BoxCloudProvider: CloudProvider {
	private let credential: BoxCredential
	private let identifierCache: BoxIdentifierCache
	private let maxPageSize: Int
	private let networkSession: NetworkSession

	public init(credential: BoxCredential, maxPageSize: Int = .max, urlSessionConfiguration: URLSessionConfiguration) throws {
		self.credential = credential
		self.identifierCache = try BoxIdentifierCache()
		self.maxPageSize = max(1, min(maxPageSize, 1000))
		self.networkSession = NetworkSession(configuration: urlSessionConfiguration)
	}

	public convenience init(credential: BoxCredential, maxPageSize: Int = .max) throws {
		try self.init(credential: credential, maxPageSize: maxPageSize, urlSessionConfiguration: .default)
	}

	public static func withBackgroundSession(credential: BoxCredential, maxPageSize: Int = .max, sessionIdentifier: String) throws -> BoxCloudProvider {
		let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
		configuration.sharedContainerIdentifier = BoxSetup.constants.sharedContainerIdentifier
		return try BoxCloudProvider(credential: credential, maxPageSize: maxPageSize, urlSessionConfiguration: configuration)
	}

	public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
		return resolvePath(forItemAt: cloudPath).then { item in
			self.fetchItemMetadata(for: item)
		}
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		return resolvePath(forItemAt: cloudPath).then { item in
			self.fetchItemList(for: item, pageToken: pageToken)
		}
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<Void> {
		precondition(localURL.isFileURL)
		if FileManager.default.fileExists(atPath: localURL.path) {
			return Promise(CloudProviderError.itemAlreadyExists)
		}
		return resolvePath(forItemAt: cloudPath).then { item in
			self.downloadFile(for: item, to: localURL, onTaskCreation: onTaskCreation)
		}
	}

	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		var isDirectory: ObjCBool = false
		let fileExists = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
		if !fileExists {
			return Promise(CloudProviderError.itemNotFound)
		}
		if isDirectory.boolValue {
			return Promise(CloudProviderError.itemTypeMismatch)
		}
		return fetchItemMetadata(at: cloudPath).then { metadata -> Void in
			if !replaceExisting || (replaceExisting && metadata.itemType == .folder) {
				throw CloudProviderError.itemAlreadyExists
			}

		}.recover { error -> Void in
			guard case CloudProviderError.itemNotFound = error else {
				throw error
			}
		}.then { _ -> Promise<BoxItem> in
			return self.resolveParentPath(forItemAt: cloudPath)
		}.then { parentItem in
			return self.uploadFile(for: parentItem, from: localURL, to: cloudPath, onTaskCreation: onTaskCreation)
		}
	}

	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: cloudPath).then { itemExists in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then { _ -> Promise<BoxItem> in
			return self.resolveParentPath(forItemAt: cloudPath)
		}.then { parentItem in
			return self.createFolder(for: parentItem, with: cloudPath.lastPathComponent)
		}
	}

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		return resolvePath(forItemAt: cloudPath).then { item in
			self.deleteFile(for: item)
		}
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		return resolvePath(forItemAt: cloudPath).then { item in
			self.deleteFolder(for: item)
		}
	}

	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: targetCloudPath).then { itemExists -> Void in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then {
			return all(self.resolvePath(forItemAt: sourceCloudPath), self.resolveParentPath(forItemAt: targetCloudPath))
		}.then { item, targetParentItem in
			return self.moveFile(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
		}
	}

	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		return checkForItemExistence(at: targetCloudPath).then { itemExists -> Void in
			if itemExists {
				throw CloudProviderError.itemAlreadyExists
			}
		}.then {
			return all(self.resolvePath(forItemAt: sourceCloudPath), self.resolveParentPath(forItemAt: targetCloudPath))
		}.then { item, targetParentItem in
			return self.moveFolder(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
		}
	}

	// MARK: - Operations

	private func fetchItemMetadata(for item: BoxItem) -> Promise<CloudItemMetadata> {
		if item.itemType == .file {
			return fetchFileMetadata(for: item)
		} else if item.itemType == .folder {
			return fetchFolderMetadata(for: item)
		} else {
			let error = CloudProviderError.itemTypeMismatch
			CloudAccessDDLogDebug("BoxCloudProvider: fetchItemMetadata(for: \(item.identifier)) failed with error: \(error)")
			return Promise(error)
		}
	}

	private func fetchFileMetadata(for item: BoxItem) -> Promise<CloudItemMetadata> {
		assert(item.itemType == .file)
		CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item)) called")

		let client = credential.client

		let pendingPromise = Promise<CloudItemMetadata>.pending()

		_Concurrency.Task {
			do {
				let fileMetadata = try await client.files.getFileById(fileId: item.identifier)
				let cloudMetadata = convertToCloudItemMetadata(fileMetadata, at: item.cloudPath)
				CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) successful")
				pendingPromise.fulfill(cloudMetadata)
			} catch let error as BoxSDKError where error.message.contains("Developer token has expired") {
				CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) error: unauthorized access")
				pendingPromise.reject(CloudProviderError.unauthorized)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func fetchFolderMetadata(for item: BoxItem) -> Promise<CloudItemMetadata> {
		assert(item.itemType == .folder)
		CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) called")

		let client = credential.client

		let pendingPromise = Promise<CloudItemMetadata>.pending()

		_Concurrency.Task {
			do {
				let fileMetadata = try await client.folders.getFolderById(folderId: item.identifier)
				let cloudMetadata = convertToCloudItemMetadata(fileMetadata, at: item.cloudPath)
				CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) successful")
				pendingPromise.fulfill(cloudMetadata)
			} catch let error as BoxSDKError where error.message.contains("Developer token has expired") {
				CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) error: unauthorized access")
				pendingPromise.reject(CloudProviderError.unauthorized)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func fetchItemList(for folderItem: BoxItem, pageToken: String?) -> Promise<CloudItemList> {
		guard folderItem.itemType == .folder else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}

		let client = credential.client

		let pendingPromise = Promise<CloudItemList>.pending()

		_Concurrency.Task {
			do {
				let queryParams = GetFolderItemsQueryParams(fields: ["name", "size", "modified_at"], usemarker: true, marker: pageToken, limit: Int64(self.maxPageSize))
				let page = try await client.folders.getFolderItems(folderId: folderItem.identifier, queryParams: queryParams)
				if let entries = page.entries {
					let allItems = entries.compactMap { entry -> CloudItemMetadata? in
						switch entry {
						case let .fileFull(file):
							return self.convertToCloudItemMetadata(file, at: folderItem.cloudPath.appendingPathComponent(file.name ?? ""))
						case let .folderMini(folder):
							return self.convertToCloudItemMetadata(folder, at: folderItem.cloudPath.appendingPathComponent(folder.name ?? ""))
						case .webLink:
							// Handling of web links as required
							return nil
						}
					}
					pendingPromise.fulfill(CloudItemList(items: allItems, nextPageToken: nil))
				} else {
					pendingPromise.reject(BoxError.unexpectedContent)
				}
			} catch {
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func downloadFile(for item: BoxItem, to localURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) called")
		guard item.itemType == .file else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}

		let client = credential.client

		let pendingPromise = Promise<Void>.pending()

		_Concurrency.Task {
			do {
				let request = try await client.downloads.downloadFile(fileId: item.identifier, downloadDestinationURL: localURL)
				let task = networkSession.session.downloadTask(with: request) { url, _, error in
					if let error = error {
						CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) failed with error: \(error.localizedDescription)")
						pendingPromise.reject(error)
					} else if let url = url {
						do {
							try FileManager.default.moveItem(at: url, to: localURL)
							CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) succeeded")
							pendingPromise.fulfill(())
						} catch {
							CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) failed with error: \(error.localizedDescription)")
							pendingPromise.reject(error)
						}
					}
				}

				onTaskCreation?(task)
				task.resume()
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func uploadFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata> {
		let client = credential.client
		let pendingPromise = Promise<CloudItemMetadata>.pending()

		_Concurrency.Task {
			do {
				// TODO: Change Error Type
				let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
				guard let fileSize = attributes[.size] as? Int64 else {
					throw CloudProviderError.unauthorized
				}

				guard FileManager.default.fileExists(atPath: localURL.path) else {
					throw CloudProviderError.itemNotFound
				}

				let targetFileName = cloudPath.lastPathComponent

				if fileSize > 20 * 1024 * 1024 {
					// Use Chunked Upload API for files larger than 20MB
					CloudAccessDDLogDebug("BoxCloudProvider: Starting chunked upload for file: \(targetFileName)")
					chunkedFileUpload(client: client, from: localURL, fileSize: fileSize, targetFileName: targetFileName, parentItem: parentItem, cloudPath: cloudPath, onTaskCreation: onTaskCreation).then { metadata in
						pendingPromise.fulfill(metadata)
					}.catch { error in
						pendingPromise.reject(error)
					}
				} else {
					// Use normal upload for smaller files
					CloudAccessDDLogDebug("BoxCloudProvider: Starting normal upload for file: \(targetFileName)")
					normalFileUpload(for: parentItem, from: localURL, to: cloudPath, onTaskCreation: onTaskCreation).then { metadata in
						pendingPromise.fulfill(metadata)
					}.catch { error in
						pendingPromise.reject(error)
					}
				}
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func normalFileUpload(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata> {
		let client = credential.client
		let pendingPromise = Promise<CloudItemMetadata>.pending()

		_Concurrency.Task {
			do {
				guard let fileStream = InputStream(url: localURL) else {
					CloudAccessDDLogDebug("BoxCloudProvider: normalFileUpload(for: \(parentItem.identifier), to: \(cloudPath)) - file not found")
					return pendingPromise.reject(CloudProviderError.itemNotFound)
				}

				let targetFileName = cloudPath.lastPathComponent

				do {
					let existingItem = try await resolvePath(forItemAt: cloudPath).async()
					let requestBody = UploadFileVersionRequestBody(
						attributes: UploadFileVersionRequestBodyAttributesField(name: targetFileName),
						file: fileStream,
						fileFileName: targetFileName
					)
					// Use InputStream directly for uploading
					let files = try await client.uploads.uploadFileVersion(fileId: existingItem.identifier, requestBody: requestBody)

					if let updatedFile = files.entries?.first {
						let cloudMetadata = convertToCloudItemMetadata(updatedFile, at: cloudPath)
						CloudAccessDDLogDebug("BoxCloudProvider: normalFileUpload(for: \(parentItem.identifier), to: \(cloudPath)) succeeded")
						pendingPromise.fulfill(cloudMetadata)
					} else {
						throw CloudProviderError.itemNotFound
					}
				} catch CloudProviderError.itemNotFound {
					let requestBody = UploadFileRequestBody(
						attributes: UploadFileRequestBodyAttributesField(
							name: targetFileName,
							parent: UploadFileRequestBodyAttributesParentField(id: parentItem.identifier)
						),
						file: fileStream,
						fileFileName: targetFileName
					)
					// Use InputStream directly for uploading
					let files = try await client.uploads.uploadFile(requestBody: requestBody)

					if let newFile = files.entries?.first {
						let cloudMetadata = convertToCloudItemMetadata(newFile, at: cloudPath)
						CloudAccessDDLogDebug("BoxCloudProvider: normalFileUpload(for: \(parentItem.identifier), to: \(cloudPath)) new file created successfully")
						pendingPromise.fulfill(cloudMetadata)
					} else {
						throw CloudProviderError.itemNotFound
					}
				} catch {
					CloudAccessDDLogDebug("BoxCloudProvider: normalFileUpload(for: \(parentItem.identifier), to: \(cloudPath)) failed with error: \(error.localizedDescription)")
					pendingPromise.reject(error)
				}
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: normalFileUpload(for: \(parentItem.identifier), to: \(cloudPath)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func chunkedFileUpload(client: BoxClient, from localURL: URL, fileSize: Int64, targetFileName: String, parentItem: BoxItem, cloudPath: CloudPath, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata> {
		let pendingPromise = Promise<CloudItemMetadata>.pending()

		_Concurrency.Task {
			do {
				let requestBody = CreateFileUploadSessionRequestBody(folderId: parentItem.identifier, fileSize: fileSize, fileName: targetFileName)
				let uploadSession = try await client.chunkedUploads.createFileUploadSession(requestBody: requestBody)

				guard let uploadSessionId = uploadSession.id else {
					throw BoxSDKError(message: "Failed to retrieve upload session ID")
				}
				CloudAccessDDLogDebug("BoxCloudProvider: Upload session created with ID: \(uploadSessionId)")

				let chunkSize = uploadSession.partSize ?? 8 * 1024 * 1024 // Default to 8MB per chunk
				var bytesUploaded: Int64 = 0
				var partArray: [UploadPart] = []

				guard let fileStream = InputStream(url: localURL) else {
					throw BoxSDKError(message: "Unable to create input stream from file URL")
				}

				fileStream.open()
				var totalSHA1 = Insecure.SHA1()

				while bytesUploaded < fileSize {
					var buffer = [UInt8](repeating: 0, count: Int(chunkSize))
					let bytesRead = fileStream.read(&buffer, maxLength: buffer.count)
					if bytesRead < 0 {
						throw fileStream.streamError ?? BoxSDKError(message: "Unknown file stream error")
					}

					let chunkData = Data(buffer[0 ..< bytesRead])
					let range = bytesUploaded ..< bytesUploaded + Int64(bytesRead)
					let contentRange = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(fileSize)"

					let sha1 = Insecure.SHA1.hash(data: chunkData)
					let sha1Base64 = Data(sha1).base64EncodedString()
					let digestHeader = "sha=\(sha1Base64)"
					totalSHA1.update(data: chunkData)

					let headers = UploadFilePartHeaders(digest: digestHeader, contentRange: contentRange)
					CloudAccessDDLogDebug("BoxCloudProvider: Uploading chunk with content range: \(contentRange)")

					let uploadedPart = try await client.chunkedUploads.uploadFilePart(uploadSessionId: uploadSessionId, requestBody: InputStream(data: chunkData), headers: headers)

					if let part = uploadedPart.part {
						partArray.append(part)
					} else {
						throw BoxSDKError(message: "Failed to retrieve upload part")
					}

					bytesUploaded += Int64(bytesRead)
				}

				fileStream.close()

				let finalSha1Base64 = Data(totalSHA1.finalize()).base64EncodedString()
				let digestHeaderFinal = "sha=\(finalSha1Base64)"
				let commitRequestBody = CreateFileUploadSessionCommitRequestBody(parts: partArray)
				let commitHeaders = CreateFileUploadSessionCommitHeaders(digest: digestHeaderFinal)
				CloudAccessDDLogDebug("BoxCloudProvider: Committing upload session with ID: \(uploadSessionId)")

				let commitResponse = try await client.chunkedUploads.createFileUploadSessionCommit(uploadSessionId: uploadSession.id ?? "", requestBody: commitRequestBody, headers: commitHeaders)

				guard let file = commitResponse.entries?.first else {
					throw CloudProviderError.itemNotFound
				}

				let cloudMetadata = convertToCloudItemMetadata(file, at: cloudPath)
				CloudAccessDDLogDebug("BoxCloudProvider: chunkedFileUpload(for: \(parentItem.identifier), to: \(cloudPath)) succeeded")
				pendingPromise.fulfill(cloudMetadata)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: chunkedFileUpload(for: \(parentItem.identifier), to: \(cloudPath)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func createFolder(for parentItem: BoxItem, with name: String) -> Promise<Void> {
		let client = credential.client

		let pendingPromise = Promise<Void>.pending()

		_Concurrency.Task {
			do {
				let folder = try await client.folders.createFolder(requestBody: CreateFolderRequestBody(name: name, parent: CreateFolderRequestBodyParentField(id: parentItem.identifier)))
				CloudAccessDDLogDebug("BoxCloudProvider: createFolder successful with folder ID: \(folder.id)")
				let newItem = BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), identifier: folder.id, itemType: .folder)
				try self.identifierCache.addOrUpdate(newItem)
				pendingPromise.fulfill(())
			} catch let error as BoxSDKError where error.message.contains("Developer token has expired") {
				CloudAccessDDLogDebug("BoxCloudProvider: createFolder failed with error: unauthorized access")
				pendingPromise.reject(CloudProviderError.unauthorized)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: createFolder failed with error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func deleteFile(for item: BoxItem) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) called")
		guard item.itemType == .file else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}

		let client = credential.client

		let pendingPromise = Promise<Void>.pending()

		_Concurrency.Task {
			do {
				try await client.files.deleteFileById(fileId: item.identifier)
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) succeeded")
				do {
					try self.identifierCache.invalidate(item)
					pendingPromise.fulfill(())
				} catch {
					CloudAccessDDLogDebug("BoxCloudProvider: Cache update failed with error: \(error)")
					pendingPromise.reject(error)
				}
			} catch let error as BoxSDKError where error.message.contains("Developer token has expired") {
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) failed with error: unauthorized access")
				pendingPromise.reject(CloudProviderError.unauthorized)
			} catch let error as BoxSDKError where error.message.contains("notFound") {
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) failed with error: not found")
				pendingPromise.reject(CloudProviderError.itemNotFound)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func deleteFolder(for item: BoxItem) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) called")
		guard item.itemType == .folder else {
			return Promise(CloudProviderError.itemTypeMismatch)
		}

		let client = credential.client

		let pendingPromise = Promise<Void>.pending()

		_Concurrency.Task {
			do {
				let queryParams = DeleteFolderByIdQueryParams(recursive: true)
				try await client.folders.deleteFolderById(folderId: item.identifier, queryParams: queryParams)
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) succeeded")
				do {
					try self.identifierCache.invalidate(item)
					pendingPromise.fulfill(())
				} catch {
					CloudAccessDDLogDebug("BoxCloudProvider: Cache update failed with error: \(error)")
					pendingPromise.reject(error)
				}
			} catch let error as BoxSDKError where error.message.contains("Developer token has expired") {
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) failed with error: unauthorized access")
				pendingPromise.reject(CloudProviderError.unauthorized)
			} catch let error as BoxSDKError where error.message.contains("notFound") {
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) failed with error: not found")
				pendingPromise.reject(CloudProviderError.itemNotFound)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) failed with error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func moveFile(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")

		let client = credential.client

		let pendingPromise = Promise<Void>.pending()

		_Concurrency.Task {
			do {
				let newName = targetCloudPath.lastPathComponent
				let parentId = UpdateFileByIdRequestBodyParentField(id: targetParentItem.identifier)
				let requestBody = UpdateFileByIdRequestBody(name: newName, parent: parentId)
				_ = try await client.files.updateFileById(fileId: sourceItem.identifier, requestBody: requestBody)
				CloudAccessDDLogDebug("BoxCloudProvider: moveFile succeeded for \(sourceItem.identifier) to \(targetCloudPath.path)")
				do {
					try self.identifierCache.invalidate(sourceItem)
					let newItem = BoxItem(cloudPath: targetCloudPath, identifier: sourceItem.identifier, itemType: sourceItem.itemType)
					try self.identifierCache.addOrUpdate(newItem)
					pendingPromise.fulfill(())
				} catch {
					CloudAccessDDLogDebug("BoxCloudProvider: Cache update failed with error: \(error)")
					pendingPromise.reject(error)
				}
			} catch let error as BoxSDKError where error.message.contains("Developer token has expired") {
				CloudAccessDDLogDebug("BoxCloudProvider: moveFile failed for \(sourceItem.identifier) with error: unauthorized access")
				pendingPromise.reject(CloudProviderError.unauthorized)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: moveFile failed for \(sourceItem.identifier) with error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	private func moveFolder(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) -> Promise<Void> {
		CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")

		let client = credential.client

		let pendingPromise = Promise<Void>.pending()

		_Concurrency.Task {
			do {
				let newName = targetCloudPath.lastPathComponent
				let parentId = UpdateFolderByIdRequestBodyParentField(id: targetParentItem.identifier)
				let requestBody = UpdateFolderByIdRequestBody(name: newName, parent: parentId)
				_ = try await client.folders.updateFolderById(folderId: sourceItem.identifier, requestBody: requestBody)
				CloudAccessDDLogDebug("BoxCloudProvider: moveFolder succeeded for \(sourceItem.identifier) to \(targetCloudPath.path)")
				do {
					try self.identifierCache.invalidate(sourceItem)
					let newItem = BoxItem(cloudPath: targetCloudPath, identifier: sourceItem.identifier, itemType: sourceItem.itemType)
					try self.identifierCache.addOrUpdate(newItem)
					pendingPromise.fulfill(())
				} catch {
					CloudAccessDDLogDebug("BoxCloudProvider: Cache update failed with error: \(error)")
					pendingPromise.reject(error)
				}
			} catch let error as BoxSDKError where error.message.contains("Developer token has expired") {
				CloudAccessDDLogDebug("BoxCloudProvider: moveFolder failed for \(sourceItem.identifier) with error: unauthorized access")
				pendingPromise.reject(CloudProviderError.unauthorized)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: moveFolder failed for \(sourceItem.identifier) with error: \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	// MARK: - Resolve Path

	private func resolvePath(forItemAt cloudPath: CloudPath) -> Promise<BoxItem> {
		var pathToCheckForCache = cloudPath
		var cachedItem = identifierCache.get(pathToCheckForCache)
		while cachedItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
			pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
			cachedItem = identifierCache.get(pathToCheckForCache)
		}
		guard let item = cachedItem else {
			return Promise(BoxError.inconsistentCache)
		}
		if pathToCheckForCache != cloudPath {
			return traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: item)
		}
		return Promise(item)
	}

	private func resolveParentPath(forItemAt cloudPath: CloudPath) -> Promise<BoxItem> {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		return resolvePath(forItemAt: parentCloudPath).recover { error -> BoxItem in
			if case CloudProviderError.itemNotFound = error {
				throw CloudProviderError.parentFolderDoesNotExist
			} else {
				throw error
			}
		}
	}

	private func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: BoxItem) -> Promise<BoxItem> {
		assert(startCloudPath.pathComponents.count < endCloudPath.pathComponents.count)
		let startIndex = startCloudPath.pathComponents.count
		let endIndex = endCloudPath.pathComponents.count
		var currentPath = startCloudPath
		var parentItem = startItem
		return Promise(on: .global()) { fulfill, _ in
			for i in startIndex ..< endIndex {
				let itemName = endCloudPath.pathComponents[i]
				currentPath = currentPath.appendingPathComponent(itemName)
				parentItem = try awaitPromise(self.getBoxItem(for: itemName, withParentItem: parentItem))
				try self.identifierCache.addOrUpdate(parentItem)
			}
			fulfill(parentItem)
		}
	}

	func getBoxItem(for name: String, withParentItem parentItem: BoxItem) -> Promise<BoxItem> {
		let client = credential.client

		let pendingPromise = Promise<BoxItem>.pending()

		_Concurrency.Task {
			do {
				var foundItem: BoxItem?
				var keepFetching = true
				var nextMarker: String?

				while keepFetching {
					let queryParams = GetFolderItemsQueryParams(fields: ["name", "size", "modified_at"], usemarker: true, marker: nextMarker, limit: Int64(self.maxPageSize))
					let page = try await client.folders.getFolderItems(folderId: parentItem.identifier, queryParams: queryParams)

					if let entries = page.entries {
						for entry in entries {
							if let mappedItem = try self.mapEntryToBoxItem(name: name, parentItem: parentItem, entry: entry) {
								foundItem = mappedItem
							}
						}
					}
					keepFetching = false // TODO: fix when nextMarker is available
				}

				if let item = foundItem {
					CloudAccessDDLogDebug("BoxCloudProvider: Found item \(name) in folder \(parentItem.identifier)")
					pendingPromise.fulfill(item)
				} else {
					CloudAccessDDLogDebug("BoxCloudProvider: Item \(name) not found in folder \(parentItem.identifier)")
					pendingPromise.reject(CloudProviderError.itemNotFound)
				}
			} catch let error as BoxSDKError where error.message.contains("Developer token has expired") {
				CloudAccessDDLogDebug("BoxCloudProvider: Unauthorized access error while searching for item \(name) in folder \(parentItem.identifier)")
				pendingPromise.reject(CloudProviderError.unauthorized)
			} catch {
				CloudAccessDDLogDebug("BoxCloudProvider: Error searching for item \(name) in folder \(parentItem.identifier): \(error.localizedDescription)")
				pendingPromise.reject(error)
			}
		}

		return pendingPromise
	}

	func mapEntryToBoxItem(name: String, parentItem: BoxItem, entry: FileFullOrFolderMiniOrWebLink) throws -> BoxItem? {
		switch entry {
		case let .fileFull(file) where file.name == name:
			return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), file: file)
		case let .folderMini(folder) where folder.name == name:
			return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), folder: folder)
		case .webLink:
			throw BoxError.unexpectedContent
		default:
			return nil
		}
	}

	// MARK: - Helpers

	private func convertToCloudItemMetadata(_ content: FileOrFolderOrWebLink, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		switch content {
		case let .file(fileMetadata):
			return convertToCloudItemMetadata(fileMetadata, at: cloudPath)
		case let .folder(folderMetadata):
			return convertToCloudItemMetadata(folderMetadata, at: cloudPath)
		default:
			throw BoxError.unexpectedContent
		}
	}

	private func convertToCloudItemMetadata(_ metadata: File, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = metadata.name ?? ""
		let itemType = CloudItemType.file
		let size = metadata.size.map { Int($0) }
		let lastModifiedDate = metadata.modifiedAt
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
	}

	private func convertToCloudItemMetadata(_ metadata: Folder, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = metadata.name ?? ""
		let itemType = CloudItemType.folder
		let lastModifiedDate = metadata.modifiedAt
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: nil)
	}

	private func convertToCloudItemMetadata(_ metadata: FileFull, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = metadata.name ?? ""
		let itemType = CloudItemType.file
		let size = metadata.size.map { Int($0) }
		let lastModifiedDate = metadata.modifiedAt
		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
	}

	private func convertToCloudItemMetadata(_ metadata: FolderMini, at cloudPath: CloudPath) -> CloudItemMetadata {
		let name = metadata.name ?? ""
		let itemType = CloudItemType.folder

		return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: nil, size: nil)
	}

	private func convertToCloudItemList(_ contents: [FileOrFolderOrWebLink], at cloudPath: CloudPath) throws -> CloudItemList {
		var items = [CloudItemMetadata]()
		for content in contents {
			switch content {
			case let .file(fileMetadata):
				let itemCloudPath = cloudPath.appendingPathComponent(fileMetadata.name ?? "")
				let itemMetadata = convertToCloudItemMetadata(fileMetadata, at: itemCloudPath)
				items.append(itemMetadata)
			case let .folder(folderMetadata):
				let itemCloudPath = cloudPath.appendingPathComponent(folderMetadata.name ?? "")
				let itemMetadata = convertToCloudItemMetadata(folderMetadata, at: itemCloudPath)
				items.append(itemMetadata)
			default:
				throw BoxError.unexpectedContent
			}
		}
		return CloudItemList(items: items, nextPageToken: nil)
	}

	private func convertToCloudItemList(_ contents: Files, at cloudPath: CloudPath) throws -> CloudItemList {
		var items = [CloudItemMetadata]()
		guard let entries = contents.entries else {
			return CloudItemList(items: [])
		}
		for content in entries {
			let itemCloudPath = cloudPath.appendingPathComponent(content.name ?? "")
			let itemMetadata = convertToCloudItemMetadata(content, at: itemCloudPath)
			items.append(itemMetadata)
		}
		return CloudItemList(items: items, nextPageToken: nil)
	}
}
