//
//  DropboxCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import ObjectiveDropboxOfficial
import Promises

public class DropboxCloudProvider: CloudProvider {
	private let credential: DropboxCredential

	private var runningTasks: [DBTask]
	private var runningBatchUploadTasks: [DBBatchUploadTask]

	let shouldRetryForError: (Error) -> Bool = { error in
		guard let dropboxError = error as? DropboxError else {
			return false
		}
		switch dropboxError {
		case .tooManyWriteOperations, .internalServerError, .rateLimitError(retryAfter: _):
			return true
		default:
			return false
		}
	}

	public init(credential: DropboxCredential) {
		self.credential = credential
		self.runningTasks = [DBTask]()
		self.runningBatchUploadTasks = [DBBatchUploadTask]()
	}

	deinit {
		for task in runningTasks {
			task.cancel()
		}
		for task in runningBatchUploadTasks {
			task.cancel()
		}
	}

	public func fetchItemMetadata(at path: CloudPath) -> Promise<CloudItemMetadata> {
		guard let authorizedClient = credential.authorizedClient else {
			return Promise(CloudProviderError.unauthorized)
		}
		return retryWithExponentialBackoff({
			self.fetchItemMetadata(at: path, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
		guard let authorizedClient = credential.authorizedClient else {
			return Promise(CloudProviderError.unauthorized)
		}
		return retryWithExponentialBackoff({
			self.fetchItemList(at: cloudPath, withPageToken: pageToken, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void> {
		precondition(localURL.isFileURL)
		guard let authorizedClient = credential.authorizedClient else {
			return Promise(CloudProviderError.unauthorized)
		}
		let progress = Progress(totalUnitCount: 1)
		return retryWithExponentialBackoff({
			progress.becomeCurrent(withPendingUnitCount: 1)
			let downloadPromise = self.downloadFile(from: cloudPath, to: localURL, with: authorizedClient)
			progress.resignCurrent()
			return downloadPromise
		}, condition: shouldRetryForError).recover { error -> Promise<Void> in
			// Currently, we get a 409 (requestError) instead of a 404 (routeError) error when we download a file that does not exist.
			// We also get this when a download was performed on a folder.
			// Therefore, we currently need to check if there is a folder on the given `cloudPath`.
			// See: https://github.com/cryptomator/cloud-access-swift/issues/6
			guard case CloudProviderError.itemNotFound = error else {
				return Promise(error)
			}
			return self.checkForItemExistence(at: cloudPath).then { itemExists in
				if itemExists {
					return Promise(CloudProviderError.itemTypeMismatch)
				} else {
					return Promise(error)
				}
			}
		}
	}

	/**
	   - Warning: This function is not atomic, because the existence of the parent folder is checked first, otherwise Dropbox creates the missing folders automatically.
	 */
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata> {
		precondition(localURL.isFileURL)
		guard let authorizedClient = credential.authorizedClient else {
			return Promise(CloudProviderError.unauthorized)
		}
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
		let progress = Progress(totalUnitCount: 1)
		let mode = replaceExisting ? DBFILESWriteMode(overwrite: ()) : nil
		let fileSize = attributes[FileAttributeKey.size] as? Int ?? 157_286_400
		// Dropbox recommends uploading files over 150mb with a batchUpload.
		if fileSize >= 157_286_400 {
			return retryWithExponentialBackoff({
				progress.becomeCurrent(withPendingUnitCount: 1)
				let uploadPromise = self.uploadLargeFile(from: localURL, to: cloudPath, mode: mode, with: authorizedClient)
				progress.resignCurrent()
				return uploadPromise
			}, condition: shouldRetryForError)
		} else {
			return retryWithExponentialBackoff({
				progress.becomeCurrent(withPendingUnitCount: 1)
				let uploadPromise = self.uploadSmallFile(from: localURL, to: cloudPath, mode: mode, with: authorizedClient)
				progress.resignCurrent()
				return uploadPromise
			}, condition: shouldRetryForError)
		}
	}

	/**
	 - Warning: This function is not atomic, because the existence of the parent folder is checked first, otherwise Dropbox creates the missing folders automatically.
	 */
	public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
		guard let authorizedClient = credential.authorizedClient else {
			return Promise(CloudProviderError.unauthorized)
		}
		return retryWithExponentialBackoff({
			self.createFolder(at: cloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
		guard let authorizedClient = credential.authorizedClient else {
			return Promise(CloudProviderError.unauthorized)
		}
		return retryWithExponentialBackoff({
			self.deleteItem(at: cloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
		guard let authorizedClient = credential.authorizedClient else {
			return Promise(CloudProviderError.unauthorized)
		}
		return retryWithExponentialBackoff({
			self.deleteItem(at: cloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	/**
	 - Warning: This function is not atomic, because the existence of the parentFolder of the target must be checked, otherwise Dropbox creates the missing folders automatically.
	 */
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		guard let authorizedClient = credential.authorizedClient else {
			return Promise(CloudProviderError.unauthorized)
		}
		return retryWithExponentialBackoff({
			self.moveItem(from: sourceCloudPath, to: targetCloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	/**
	 - Warning: This function is not atomic, because the existence of the parentFolder of the target must be checked, otherwise Dropbox creates the missing folders automatically.
	 */
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
		guard let authorizedClient = credential.authorizedClient else {
			return Promise(CloudProviderError.unauthorized)
		}
		return retryWithExponentialBackoff({
			self.moveItem(from: sourceCloudPath, to: targetCloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	// MARK: - Dropbox Operations

	private func fetchItemMetadata(at cloudPath: CloudPath, with client: DBUserClient) -> Promise<CloudItemMetadata> {
		return Promise<CloudItemMetadata> { fulfill, reject in
			let task = client.filesRoutes.getMetadata(cloudPath.path)
			self.runningTasks.append(task)
			task.setResponseBlock { metadata, routeError, networkError in
				self.runningTasks.removeAll { $0 == task }
				if let routeError = routeError {
					if routeError.isPath(), routeError.path.isNotFound() {
						reject(CloudProviderError.itemNotFound)
					} else {
						reject(DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError = networkError {
					reject(self.convertRequestErrorToDropboxError(networkError))
					return
				}
				guard let metadata = metadata else {
					reject(DropboxError.missingResult)
					return
				}
				do {
					fulfill(try self.convertDBFILESMetadataToCloudItemMetadata(metadata, at: cloudPath))
				} catch {
					reject(error)
				}
			}
		}
	}

	private func fetchItemList(at cloudPath: CloudPath, withPageToken pageToken: String?, with client: DBUserClient) -> Promise<CloudItemList> {
		if let pageToken = pageToken {
			return fetchItemListContinue(at: cloudPath, withPageToken: pageToken, with: client)
		} else {
			return fetchItemList(at: cloudPath, with: client)
		}
	}

	private func fetchItemList(at cloudPath: CloudPath, with client: DBUserClient) -> Promise<CloudItemList> {
		return Promise<CloudItemList> { fulfill, reject in
			// Dropbox differs from the filesystem hierarchy standard and accepts instead of "/" only a "".
			// Therefore, `cloudPath` must be checked for the root path and adjusted if necessary.
			let cleanedPath = (cloudPath == CloudPath("/")) ? "" : cloudPath.path
			let task = client.filesRoutes.listFolder(cleanedPath)
			self.runningTasks.append(task)
			task.setResponseBlock { result, routeError, networkError in
				self.runningTasks.removeAll { $0 == task }
				if let routeError = routeError {
					if routeError.isPath(), routeError.path.isNotFound() {
						reject(CloudProviderError.itemNotFound)
					} else if routeError.isPath(), routeError.path.isNotFolder() {
						reject(CloudProviderError.itemTypeMismatch)
					} else {
						reject(DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError = networkError {
					reject(self.convertRequestErrorToDropboxError(networkError))
					return
				}
				guard let result = result else {
					reject(DropboxError.missingResult)
					return
				}
				do {
					fulfill(try self.convertDBFILESListFolderResultToCloudItemList(result, at: cloudPath))
				} catch {
					reject(error)
				}
			}
		}
	}

	private func fetchItemListContinue(at cloudPath: CloudPath, withPageToken pageToken: String, with client: DBUserClient) -> Promise<CloudItemList> {
		return Promise<CloudItemList> { fulfill, reject in
			let task = client.filesRoutes.listFolderContinue(pageToken)
			self.runningTasks.append(task)
			task.setResponseBlock { result, routeError, networkError in
				self.runningTasks.removeAll { $0 == task }
				if let routeError = routeError {
					if routeError.isPath(), routeError.path.isNotFound() {
						reject(CloudProviderError.itemNotFound)
					} else if routeError.isPath(), routeError.path.isNotFolder() {
						reject(CloudProviderError.itemTypeMismatch)
					} else if routeError.isReset() {
						reject(CloudProviderError.pageTokenInvalid)
					} else {
						reject(DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError = networkError {
					if networkError.isBadInputError(), let errorContent = networkError.errorContent, errorContent.contains("invalidPageToken") {
						reject(CloudProviderError.pageTokenInvalid)
					} else {
						reject(self.convertRequestErrorToDropboxError(networkError))
					}
					return
				}
				guard let result = result else {
					reject(DropboxError.missingResult)
					return
				}
				do {
					fulfill(try self.convertDBFILESListFolderResultToCloudItemList(result, at: cloudPath))
				} catch {
					reject(error)
				}
			}
		}
	}

	private func downloadFile(from cloudPath: CloudPath, to localURL: URL, with client: DBUserClient) -> Promise<Void> {
		let progress = Progress(totalUnitCount: -1)
		return Promise<Void> { fulfill, reject in
			let task = client.filesRoutes.downloadUrl(cloudPath.path, overwrite: false, destination: localURL)
			self.runningTasks.append(task)
			task.setProgressBlock { _, totalBytesWritten, totalBytesExpectedToWrite in
				progress.totalUnitCount = totalBytesExpectedToWrite
				progress.completedUnitCount = totalBytesWritten
			}
			task.setResponseBlock { _, routeError, requestError, _ in
				self.runningTasks.removeAll { $0 == task }
				if let routeError = routeError {
					if routeError.isPath(), routeError.path.isNotFound() {
						reject(CloudProviderError.itemNotFound)
					} else {
						reject(DropboxError.unexpectedRouteError)
					}
					return
				}
				if let requestError = requestError {
					if requestError.isClientError(), case CocoaError.fileWriteFileExists = requestError.asClientError().nsError {
						reject(CloudProviderError.itemAlreadyExists)
					} else if requestError.isHttpError(), requestError.statusCode == 409 {
						// Currently, we get a 409 (requestError) instead of a 404 (routeError) error when we download a file that does not exist.
						// Until this is fixed by Dropbox, this workaround is used.
						// See: https://github.com/cryptomator/cloud-access-swift/issues/6
						reject(CloudProviderError.itemNotFound)
					} else {
						reject(self.convertRequestErrorToDropboxError(requestError))
					}
					return
				}
				fulfill(())
			}
		}
	}

	private func uploadLargeFile(from localURL: URL, to cloudPath: CloudPath, mode: DBFILESWriteMode?, with client: DBUserClient) -> Promise<CloudItemMetadata> {
		let progress = Progress(totalUnitCount: 1)
		return ensureParentFolderExists(for: cloudPath).then {
			progress.becomeCurrent(withPendingUnitCount: 1)
			let uploadPromise = self.batchUploadSingleFile(from: localURL, to: cloudPath, mode: mode, with: client)
			progress.resignCurrent()
			return uploadPromise
		}
	}

	private func batchUploadSingleFile(from localURL: URL, to cloudPath: CloudPath, mode: DBFILESWriteMode?, with client: DBUserClient) -> Promise<CloudItemMetadata> {
		let progress = Progress(totalUnitCount: -1)
		return Promise<CloudItemMetadata> { fulfill, reject in
			let commitInfo = DBFILESCommitInfo(path: cloudPath.path, mode: mode, autorename: nil, clientModified: nil, mute: nil, propertyGroups: nil, strictConflict: true)
			let uploadProgress: DBProgressBlock = { _, totalBytesUploaded, totalBytesExpectedToUpload in
				progress.totalUnitCount = totalBytesExpectedToUpload
				progress.completedUnitCount = totalBytesUploaded
			}
			var task: DBBatchUploadTask!
			task = client.filesRoutes.batchUploadFiles([localURL: commitInfo], queue: nil, progressBlock: uploadProgress) { fileUrlsToBatchResultEntries, finishBatchRouteError, finishBatchRequestError, fileUrlsToRequestErrors in
				self.runningBatchUploadTasks.removeAll { $0 == task }
				guard let result = fileUrlsToBatchResultEntries?[localURL] else {
					reject(self.handleBatchUploadMissingResult(for: localURL, fileUrlsToRequestErrors, finishBatchRouteError, finishBatchRequestError))
					return
				}
				if result.isFailure() {
					let failure = result.failure
					if failure.isPath(), failure.path.isConflict() {
						reject(CloudProviderError.itemAlreadyExists)
					} else if failure.isPath(), failure.path.isInsufficientSpace() {
						reject(CloudProviderError.quotaInsufficient)
					} else if failure.isTooManyWriteOperations() {
						reject(DropboxError.tooManyWriteOperations)
					} else {
						reject(DropboxError.unexpectedResult)
					}
				} else if result.isSuccess() {
					fulfill(self.convertDBFILESFileMetadataToCloudItemMetadata(result.success, at: cloudPath))
				} else {
					reject(DropboxError.unexpectedResult)
				}
			}
			self.runningBatchUploadTasks.append(task)
		}
	}

	func handleBatchUploadMissingResult(for localURL: URL, _ fileUrlsToRequestErrors: [URL: DBRequestError], _ finishBatchRouteError: DBASYNCPollError?, _ finishBatchRequestError: DBRequestError?) -> Error {
		if !fileUrlsToRequestErrors.isEmpty {
			guard let requestError = fileUrlsToRequestErrors[localURL] else {
				return DropboxError.unexpectedError
			}
			return convertRequestErrorToDropboxError(requestError)
		} else if finishBatchRouteError != nil {
			return DropboxError.asyncPollError
		} else if let finishBatchRequestError = finishBatchRequestError {
			return convertRequestErrorToDropboxError(finishBatchRequestError)
		} else {
			return DropboxError.missingResult
		}
	}

	private func uploadSmallFile(from localURL: URL, to cloudPath: CloudPath, mode: DBFILESWriteMode?, with client: DBUserClient) -> Promise<CloudItemMetadata> {
		let progress = Progress(totalUnitCount: -1)
		return ensureParentFolderExists(for: cloudPath).then { _ -> Promise<CloudItemMetadata> in
			let task = client.filesRoutes.uploadUrl(cloudPath.path, mode: mode, autorename: nil, clientModified: nil, mute: nil, propertyGroups: nil, strictConflict: true, inputUrl: localURL.path)
			self.runningTasks.append(task)
			let uploadProgress: DBProgressBlock = { _, totalBytesUploaded, totalBytesExpectedToUpload in
				progress.totalUnitCount = totalBytesExpectedToUpload
				progress.completedUnitCount = totalBytesUploaded
			}
			task.setProgressBlock(uploadProgress)
			return Promise<CloudItemMetadata> { fulfill, reject in
				task.setResponseBlock { result, routeError, networkError in
					self.runningTasks.removeAll { $0 == task }
					if let routeError = routeError {
						if routeError.isPath(), routeError.path.reason.isConflict() {
							reject(CloudProviderError.itemAlreadyExists)
						} else if routeError.isPath(), routeError.path.reason.isInsufficientSpace() {
							reject(CloudProviderError.quotaInsufficient)
						} else if routeError.isPath(), routeError.path.reason.isTooManyWriteOperations() {
							reject(DropboxError.tooManyWriteOperations)
						} else {
							reject(DropboxError.unexpectedRouteError)
						}
						return
					}
					if let networkError = networkError {
						reject(self.convertRequestErrorToDropboxError(networkError))
						return
					}
					guard let result = result else {
						reject(DropboxError.missingResult)
						return
					}
					fulfill(self.convertDBFILESFileMetadataToCloudItemMetadata(result, at: cloudPath))
				}
			}
		}
	}

	private func createFolder(at cloudPath: CloudPath, with client: DBUserClient) -> Promise<Void> {
		return ensureParentFolderExists(for: cloudPath).then {
			return Promise<Void> { fulfill, reject in
				let task = client.filesRoutes.createFolderV2(cloudPath.path)
				self.runningTasks.append(task)
				task.setResponseBlock { result, routeError, networkError in
					self.runningTasks.removeAll { $0 == task }
					if let routeError = routeError {
						if routeError.isPath(), routeError.path.isConflict() {
							reject(CloudProviderError.itemAlreadyExists)
						} else if routeError.isPath(), routeError.path.isInsufficientSpace() {
							reject(CloudProviderError.quotaInsufficient)
						} else {
							reject(DropboxError.unexpectedRouteError)
						}
						return
					}
					if let networkError = networkError {
						reject(self.convertRequestErrorToDropboxError(networkError))
						return
					}
					guard result != nil else {
						reject(DropboxError.missingResult)
						return
					}
					fulfill(())
				}
			}
		}
	}

	private func deleteItem(at cloudPath: CloudPath, with client: DBUserClient) -> Promise<Void> {
		return Promise<Void> { fulfill, reject in
			let task = client.filesRoutes.delete_V2(cloudPath.path)
			self.runningTasks.append(task)
			task.setResponseBlock { result, routeError, networkError in
				self.runningTasks.removeAll { $0 == task }
				if let routeError = routeError {
					if routeError.isPathLookup(), routeError.pathLookup.isNotFound() {
						reject(CloudProviderError.itemNotFound)
					} else {
						reject(DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError = networkError {
					reject(self.convertRequestErrorToDropboxError(networkError))
					return
				}
				guard result != nil else {
					reject(DropboxError.unexpectedError)
					return
				}
				fulfill(())
			}
		}
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath, with client: DBUserClient) -> Promise<Void> {
		return ensureParentFolderExists(for: targetCloudPath).then {
			return Promise<Void> { fulfill, reject in
				let task = client.filesRoutes.moveV2(sourceCloudPath.path, toPath: targetCloudPath.path)
				self.runningTasks.append(task)
				task.setResponseBlock { _, routeError, networkError in
					self.runningTasks.removeAll { $0 == task }
					if let routeError = routeError {
						if routeError.isFromLookup(), routeError.fromLookup.isNotFound() {
							reject(CloudProviderError.itemNotFound)
						} else if routeError.isTo(), routeError.to.isConflict() {
							reject(CloudProviderError.itemAlreadyExists)
						} else if routeError.isTo(), routeError.to.isInsufficientSpace() {
							reject(CloudProviderError.quotaInsufficient)
						} else if routeError.isFromWrite(), routeError.fromWrite.isTooManyWriteOperations() {
							reject(DropboxError.tooManyWriteOperations)
						} else {
							reject(DropboxError.unexpectedRouteError)
						}
						return
					}
					if let networkError = networkError {
						reject(self.convertRequestErrorToDropboxError(networkError))
						return
					}
					fulfill(())
				}
			}
		}
	}

	func ensureParentFolderExists(for cloudPath: CloudPath) -> Promise<Void> {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		if parentCloudPath == CloudPath("/") {
			return Promise(())
		}
		return checkForItemExistence(at: parentCloudPath).then { itemExists -> Void in
			guard itemExists else {
				throw CloudProviderError.parentFolderDoesNotExist
			}
		}
	}

	func retryWithExponentialBackoff<Value>(_ work: @escaping () throws -> Promise<Value>, condition: (Error) -> Bool) -> Promise<Value> {
		let queue = DispatchQueue(label: "retryWithExponentialBackoff-Dropbox", qos: .userInitiated)
		let attempts = 5
		let exponentialBackoffBase: UInt = 2
		let exponentialBackoffScale = 0.5
		return retry(
			on: queue,
			attempts: attempts,
			delay: 0.01,
			condition: { remainingAttempts, error in
				let condition = self.shouldRetryForError(error)
				if condition {
					let jitter = Double.random(in: 0 ..< 0.5)
					if let dropboxError = error as? DropboxError, case let .rateLimitError(retryAfter) = dropboxError {
						Thread.sleep(forTimeInterval: Double(retryAfter) + jitter)
					} else {
						let retryCount = attempts - remainingAttempts
						let sleepTime = pow(Double(exponentialBackoffBase), Double(retryCount)) * exponentialBackoffScale + jitter
						Thread.sleep(forTimeInterval: sleepTime)
					}
				}
				return condition
			},
			work
		)
	}

	// MARK: - Helpers

	func convertDBFILESMetadataToCloudItemMetadata(_ metadata: DBFILESMetadata, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		if metadata is DBFILESFolderMetadata {
			return CloudItemMetadata(name: metadata.name, cloudPath: cloudPath, itemType: .folder, lastModifiedDate: nil, size: nil)
		}
		guard let fileMetadata = metadata as? DBFILESFileMetadata else {
			throw DropboxError.unexpectedResult
		}
		return convertDBFILESFileMetadataToCloudItemMetadata(fileMetadata, at: cloudPath)
	}

	func convertDBFILESFileMetadataToCloudItemMetadata(_ metadata: DBFILESFileMetadata, at cloudPath: CloudPath) -> CloudItemMetadata {
		return CloudItemMetadata(name: metadata.name, cloudPath: cloudPath, itemType: .file, lastModifiedDate: metadata.serverModified, size: metadata.size.intValue)
	}

	func convertDBFILESListFolderResultToCloudItemList(_ folderResult: DBFILESListFolderResult, at cloudPath: CloudPath) throws -> CloudItemList {
		var items = [CloudItemMetadata]()
		for metadata in folderResult.entries {
			let itemCloudPath = cloudPath.appendingPathComponent(metadata.name)
			let itemMetadata = try convertDBFILESMetadataToCloudItemMetadata(metadata, at: itemCloudPath)
			items.append(itemMetadata)
		}
		let nextPageToken = folderResult.hasMore.boolValue ? folderResult.cursor : nil
		return CloudItemList(items: items, nextPageToken: nextPageToken)
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

	func convertRequestErrorToDropboxError(_ error: DBRequestError) -> DropboxError {
		if error.isHttpError() {
			return .httpError
		} else if error.isBadInputError() {
			return .badInputError
		} else if error.isAuthError() {
			return .authError
		} else if error.isAccessError() {
			return .accessError
		} else if error.isPathRootError() {
			return .pathRootError
		} else if error.isRateLimitError() {
			let rateLimitError = error.asRateLimitError()
			return .rateLimitError(retryAfter: rateLimitError.backoff.intValue)
		} else if error.isInternalServerError() {
			return .internalServerError
		} else if error.isClientError() {
			return .clientError
		} else {
			return .unexpectedError
		}
	}
}
