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
	private let maxPageSize: Int

	let shouldRetryForError: (Error) -> Bool = { error in
		guard let dropboxError = error as? DropboxError else {
			return false
		}
		switch dropboxError {
		case .tooManyWriteOperations, .internalServerError, .rateLimitError:
			return true
		default:
			return false
		}
	}

	public init(credential: DropboxCredential, maxPageSize: Int = .max) {
		self.credential = credential
		self.runningTasks = [DBTask]()
		self.runningBatchUploadTasks = [DBBatchUploadTask]()
		self.maxPageSize = max(1, min(maxPageSize, 2000))
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

	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<Void> {
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
		}, condition: shouldRetryForError)
	}

	/**
	 - Warning: This function is not atomic, because the existence of the parent folder is checked first, otherwise Dropbox creates the missing folders automatically.
	 */
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata> {
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
			CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemMetadata(at: \(cloudPath.path)) called")
			let task = client.filesRoutes.getMetadata(cloudPath.path)
			self.runningTasks.append(task)
			task.setResponseBlock { result, routeError, networkError in
				self.runningTasks.removeAll { $0 == task }
				if let routeError = routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemMetadata(at: \(cloudPath.path)) failed with routeError: \(routeError)")
					if routeError.isPath(), routeError.path.isNotFound() {
						reject(CloudProviderError.itemNotFound)
					} else {
						reject(DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError = networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemMetadata(at: \(cloudPath.path)) failed with networkError: \(networkError)")
					reject(self.convertRequestError(networkError))
					return
				}
				guard let result = result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemMetadata(at: \(cloudPath.path)) failed with missingResult")
					reject(DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemMetadata(at: \(cloudPath.path)) received result: \(DBFILESMetadata.serialize(result) ?? [:])")
				do {
					try fulfill(self.convertDBFILESMetadataToCloudItemMetadata(result, at: cloudPath))
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
			CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemList(at: \(cloudPath.path)) called")
			// Dropbox differs from the filesystem hierarchy standard and accepts instead of "/" only a "".
			// Therefore, `cloudPath` must be checked for the root path and adjusted if necessary.
			let cleanedPath = (cloudPath == CloudPath("/")) ? "" : cloudPath.path
			let task = client.filesRoutes.listFolder(cleanedPath, recursive: nil, includeMediaInfo: nil, includeDeleted: nil, includeHasExplicitSharedMembers: nil, includeMountedFolders: nil, limit: NSNumber(value: self.maxPageSize), sharedLink: nil, includePropertyGroups: nil, includeNonDownloadableFiles: nil)
			self.runningTasks.append(task)
			task.setResponseBlock { result, routeError, networkError in
				self.runningTasks.removeAll { $0 == task }
				if let routeError = routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemList(at: \(cloudPath.path)) failed with routeError: \(routeError)")
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
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemList(at: \(cloudPath.path)) failed with networkError: \(networkError)")
					reject(self.convertRequestError(networkError))
					return
				}
				guard let result = result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemList(at: \(cloudPath.path)) failed with missingResult")
					reject(DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemList(at: \(cloudPath.path)) received result: \(DBFILESListFolderResult.serialize(result) ?? [:])")
				do {
					try fulfill(self.convertDBFILESListFolderResultToCloudItemList(result, at: cloudPath))
				} catch {
					reject(error)
				}
			}
		}
	}

	private func fetchItemListContinue(at cloudPath: CloudPath, withPageToken pageToken: String, with client: DBUserClient) -> Promise<CloudItemList> {
		return Promise<CloudItemList> { fulfill, reject in
			CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken)) called")
			let task = client.filesRoutes.listFolderContinue(pageToken)
			self.runningTasks.append(task)
			task.setResponseBlock { result, routeError, networkError in
				self.runningTasks.removeAll { $0 == task }
				if let routeError = routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken)) failed with routeError: \(routeError)")
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
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken)) failed with networkError: \(networkError)")
					if networkError.isBadInputError(), let errorContent = networkError.errorContent, errorContent.contains("invalidPageToken") {
						reject(CloudProviderError.pageTokenInvalid)
					} else {
						reject(self.convertRequestError(networkError))
					}
					return
				}
				guard let result = result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken)) failed with missingResult")
					reject(DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken)) received result: \(DBFILESListFolderResult.serialize(result) ?? [:])")
				do {
					try fulfill(self.convertDBFILESListFolderResultToCloudItemList(result, at: cloudPath))
				} catch {
					reject(error)
				}
			}
		}
	}

	private func downloadFile(from cloudPath: CloudPath, to localURL: URL, with client: DBUserClient) -> Promise<Void> {
		let progress = Progress(totalUnitCount: -1)
		return Promise<Void> { fulfill, reject in
			CloudAccessDDLogDebug("DropboxCloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) called")
			let task = client.filesRoutes.downloadUrl(cloudPath.path, overwrite: false, destination: localURL)
			self.runningTasks.append(task)
			task.setProgressBlock { _, totalBytesWritten, totalBytesExpectedToWrite in
				progress.totalUnitCount = totalBytesExpectedToWrite
				progress.completedUnitCount = totalBytesWritten
			}
			task.setResponseBlock { _, routeError, networkError, _ in
				self.runningTasks.removeAll { $0 == task }
				if let routeError = routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) failed with routeError: \(routeError)")
					if routeError.isPath(), routeError.path.isNotFound() {
						reject(CloudProviderError.itemNotFound)
					} else if routeError.isPath(), routeError.path.isNotFile() {
						reject(CloudProviderError.itemTypeMismatch)
					} else {
						reject(DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError = networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) failed with networkError: \(networkError)")
					if networkError.isClientError(), case CocoaError.fileWriteFileExists = networkError.asClientError().nsError {
						reject(CloudProviderError.itemAlreadyExists)
					} else {
						reject(self.convertRequestError(networkError))
					}
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) finished")
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
			CloudAccessDDLogDebug("DropboxCloudProvider: batchUploadSingleFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil") called")
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
				CloudAccessDDLogDebug("DropboxCloudProvider: batchUploadSingleFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) received result: \(DBFILESUploadSessionFinishBatchResultEntry.serialize(result) ?? [:])")
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
			CloudAccessDDLogDebug("DropboxCloudProvider: handleBatchUploadMissingResult(for: \(localURL)) failed with fileUrlsToRequestErrors: \(fileUrlsToRequestErrors)")
			guard let requestError = fileUrlsToRequestErrors[localURL] else {
				return DropboxError.unexpectedError
			}
			return convertRequestError(requestError)
		} else if let finishBatchRouteError = finishBatchRouteError {
			CloudAccessDDLogDebug("DropboxCloudProvider: handleBatchUploadMissingResult(for: \(localURL)) failed with finishBatchRouteError: \(finishBatchRouteError)")
			return DropboxError.asyncPollError
		} else if let finishBatchRequestError = finishBatchRequestError {
			CloudAccessDDLogDebug("DropboxCloudProvider: handleBatchUploadMissingResult(for: \(localURL)) failed with finishBatchRequestError: \(finishBatchRequestError)")
			return convertRequestError(finishBatchRequestError)
		} else {
			CloudAccessDDLogDebug("DropboxCloudProvider: handleBatchUploadMissingResult(for: \(localURL)) failed with missingResult")
			return DropboxError.missingResult
		}
	}

	private func uploadSmallFile(from localURL: URL, to cloudPath: CloudPath, mode: DBFILESWriteMode?, with client: DBUserClient) -> Promise<CloudItemMetadata> {
		let progress = Progress(totalUnitCount: -1)
		return ensureParentFolderExists(for: cloudPath).then { _ -> Promise<CloudItemMetadata> in
			CloudAccessDDLogDebug("DropboxCloudProvider: uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) called")
			let task = client.filesRoutes.uploadUrl(cloudPath.path, mode: mode, autorename: nil, clientModified: nil, mute: nil, propertyGroups: nil, strictConflict: true, contentHash: nil, inputUrl: localURL.path)
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
						CloudAccessDDLogDebug("DropboxCloudProvider: uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) failed with routeError: \(routeError)")
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
						CloudAccessDDLogDebug("DropboxCloudProvider: uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) failed with networkError: \(networkError)")
						reject(self.convertRequestError(networkError))
						return
					}
					guard let result = result else {
						CloudAccessDDLogDebug("DropboxCloudProvider: uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) failed with missingResult")
						reject(DropboxError.missingResult)
						return
					}
					CloudAccessDDLogDebug("DropboxCloudProvider: uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) received result: \(DBFILESFileMetadata.serialize(result) ?? [:])")
					fulfill(self.convertDBFILESFileMetadataToCloudItemMetadata(result, at: cloudPath))
				}
			}
		}
	}

	private func createFolder(at cloudPath: CloudPath, with client: DBUserClient) -> Promise<Void> {
		return ensureParentFolderExists(for: cloudPath).then {
			return Promise<Void> { fulfill, reject in
				CloudAccessDDLogDebug("DropboxCloudProvider: createFolder(at: \(cloudPath.path)) called")
				let task = client.filesRoutes.createFolderV2(cloudPath.path)
				self.runningTasks.append(task)
				task.setResponseBlock { result, routeError, networkError in
					self.runningTasks.removeAll { $0 == task }
					if let routeError = routeError {
						CloudAccessDDLogDebug("DropboxCloudProvider: createFolder(at: \(cloudPath.path)) failed with routeError: \(routeError)")
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
						CloudAccessDDLogDebug("DropboxCloudProvider: createFolder(at: \(cloudPath.path)) failed with networkError: \(networkError)")
						reject(self.convertRequestError(networkError))
						return
					}
					guard let result = result else {
						CloudAccessDDLogDebug("DropboxCloudProvider: createFolder(at: \(cloudPath.path)) failed with missingResult")
						reject(DropboxError.missingResult)
						return
					}
					CloudAccessDDLogDebug("DropboxCloudProvider: createFolder(at: \(cloudPath.path)) received result: \(DBFILESCreateFolderResult.serialize(result) ?? [:])")
					fulfill(())
				}
			}
		}
	}

	private func deleteItem(at cloudPath: CloudPath, with client: DBUserClient) -> Promise<Void> {
		return Promise<Void> { fulfill, reject in
			CloudAccessDDLogDebug("DropboxCloudProvider: deleteItem(at: \(cloudPath.path)) called")
			let task = client.filesRoutes.delete_V2(cloudPath.path)
			self.runningTasks.append(task)
			task.setResponseBlock { result, routeError, networkError in
				self.runningTasks.removeAll { $0 == task }
				if let routeError = routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: deleteItem(at: \(cloudPath.path)) failed with routeError: \(routeError)")
					if routeError.isPathLookup(), routeError.pathLookup.isNotFound() {
						reject(CloudProviderError.itemNotFound)
					} else {
						reject(DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError = networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: deleteItem(at: \(cloudPath.path)) failed with networkError: \(networkError)")
					reject(self.convertRequestError(networkError))
					return
				}
				guard let result = result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: deleteItem(at: \(cloudPath.path)) failed with missingResult")
					reject(DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: deleteItem(at: \(cloudPath.path)) received result: \(DBFILESDeleteResult.serialize(result) ?? [:])")
				fulfill(())
			}
		}
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath, with client: DBUserClient) -> Promise<Void> {
		return ensureParentFolderExists(for: targetCloudPath).then {
			return Promise<Void> { fulfill, reject in
				CloudAccessDDLogDebug("DropboxCloudProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) called")
				let task = client.filesRoutes.moveV2(sourceCloudPath.path, toPath: targetCloudPath.path)
				self.runningTasks.append(task)
				task.setResponseBlock { result, routeError, networkError in
					self.runningTasks.removeAll { $0 == task }
					if let routeError = routeError {
						CloudAccessDDLogDebug("DropboxCloudProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with routeError: \(routeError)")
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
						CloudAccessDDLogDebug("DropboxCloudProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with networkError: \(networkError)")
						reject(self.convertRequestError(networkError))
						return
					}
					guard let result = result else {
						CloudAccessDDLogDebug("DropboxCloudProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with missingResult")
						reject(DropboxError.missingResult)
						return
					}
					CloudAccessDDLogDebug("DropboxCloudProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) received result: \(DBFILESRelocationResult.serialize(result) ?? [:])")
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
					let sleepTime: Double
					if let dropboxError = error as? DropboxError, case let .rateLimitError(retryAfter) = dropboxError {
						sleepTime = Double(retryAfter) + jitter
					} else {
						let retryCount = attempts - remainingAttempts
						sleepTime = pow(Double(exponentialBackoffBase), Double(retryCount)) * exponentialBackoffScale + jitter
					}
					CloudAccessDDLogDebug("DropboxCloudProvider: retryWithExponentialBackoff() sleep for \(sleepTime) after error: \(error)")
					Thread.sleep(forTimeInterval: sleepTime)
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

	func convertRequestError(_ error: DBRequestError) -> Error {
		if error.isHttpError() {
			return DropboxError.httpError
		} else if error.isBadInputError() {
			return DropboxError.badInputError
		} else if error.isAuthError() {
			return CloudProviderError.unauthorized
		} else if error.isAccessError() {
			return DropboxError.accessError
		} else if error.isPathRootError() {
			return DropboxError.pathRootError
		} else if error.isRateLimitError() {
			let rateLimitError = error.asRateLimitError()
			return DropboxError.rateLimitError(retryAfter: rateLimitError.backoff.intValue)
		} else if error.isInternalServerError() {
			return DropboxError.internalServerError
		} else if error.isClientError() {
			return DropboxError.clientError
		} else {
			return DropboxError.unexpectedError
		}
	}
}
