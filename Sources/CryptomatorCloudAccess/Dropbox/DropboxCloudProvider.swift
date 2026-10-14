//
//  DropboxCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import ObjectiveDropboxOfficial
import os

public final class DropboxCloudProvider: CloudProvider {
	private let credential: DropboxCredential
	private let maxPageSize: Int

	let shouldRetryForError: @Sendable (Error) -> Bool = { error in
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
		self.maxPageSize = max(1, min(maxPageSize, 2000))
	}

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		return try await retryWithExponentialBackoff({
			try await fetchItemMetadata(at: cloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		return try await retryWithExponentialBackoff({
			try await fetchItemList(at: cloudPath, withPageToken: pageToken, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		let phases = Progress.phases(of: progress, 999)
		let transferProgress = TransferProgress(phases[0])
		let metadata = try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
			try await retryWithExponentialBackoff({
				try await downloadFile(from: cloudPath, to: stagedFile, transferProgress: transferProgress, with: authorizedClient)
			}, condition: shouldRetryForError)
		})
		phases.completeTransfer()
		return metadata
	}

	/**
	 - Warning: This function is not atomic, because the existence of the parent folder is checked first, otherwise Dropbox creates the missing folders automatically.
	 */
	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
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
		let phases = Progress.phases(of: progress, 999)
		let transferProgress = TransferProgress(phases[0])
		let mode = replaceExisting ? DBFILESWriteMode(overwrite: ()) : nil
		let fileSize = attributes[FileAttributeKey.size] as? Int ?? 157_286_400
		let metadata = try await retryWithExponentialBackoff({
			// Dropbox recommends uploading files over 150mb with a batchUpload.
			if fileSize >= 157_286_400 {
				try await uploadLargeFile(from: localURL, to: cloudPath, mode: mode, transferProgress: transferProgress, with: authorizedClient)
			} else {
				try await uploadSmallFile(from: localURL, to: cloudPath, mode: mode, transferProgress: transferProgress, with: authorizedClient)
			}
		}, condition: shouldRetryForError)
		phases.completeTransfer()
		return metadata
	}

	/**
	 - Warning: This function is not atomic, because the existence of the parent folder is checked first, otherwise Dropbox creates the missing folders automatically.
	 */
	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		try await retryWithExponentialBackoff({
			try await createFolder(at: cloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		try await retryWithExponentialBackoff({
			try await deleteItem(at: cloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		try await retryWithExponentialBackoff({
			try await deleteItem(at: cloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	/**
	 - Warning: This function is not atomic, because the existence of the parentFolder of the target must be checked, otherwise Dropbox creates the missing folders automatically.
	 */
	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		try await retryWithExponentialBackoff({
			try await moveItem(from: sourceCloudPath, to: targetCloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	/**
	 - Warning: This function is not atomic, because the existence of the parentFolder of the target must be checked, otherwise Dropbox creates the missing folders automatically.
	 */
	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		try await retryWithExponentialBackoff({
			try await moveItem(from: sourceCloudPath, to: targetCloudPath, with: authorizedClient)
		}, condition: shouldRetryForError)
	}

	// MARK: - Dropbox Operations

	private func fetchItemMetadata(at cloudPath: CloudPath, with client: DBUserClient) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemMetadata(at: \(cloudPath.path)) called")
		return try await withMainActorSDKContinuation { resumer in
			let task = client.filesRoutes.getMetadata(cloudPath.path)
			task.setResponseBlock { result, routeError, networkError in
				if let routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemMetadata(at: \(cloudPath.path)) failed with routeError: \(routeError)")
					if routeError.isPath(), routeError.path.isNotFound() {
						resumer.resume(throwing: CloudProviderError.itemNotFound)
					} else {
						resumer.resume(throwing: DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemMetadata(at: \(cloudPath.path)) failed with networkError: \(networkError)")
					resumer.resume(throwing: self.convertRequestError(networkError))
					return
				}
				guard let result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemMetadata(at: \(cloudPath.path)) failed with missingResult")
					resumer.resume(throwing: DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemMetadata(at: \(cloudPath.path)) received result: \(DBFILESMetadata.serialize(result) ?? [:])")
				do {
					try resumer.resume(returning: self.convertDBFILESMetadataToCloudItemMetadata(result, at: cloudPath))
				} catch {
					resumer.resume(throwing: error)
				}
			}
		}
	}

	private func fetchItemList(at cloudPath: CloudPath, withPageToken pageToken: String?, with client: DBUserClient) async throws -> CloudItemList {
		if let pageToken {
			return try await fetchItemListContinue(at: cloudPath, withPageToken: pageToken, with: client)
		} else {
			return try await fetchItemList(at: cloudPath, with: client)
		}
	}

	private func fetchItemList(at cloudPath: CloudPath, with client: DBUserClient) async throws -> CloudItemList {
		CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemList(at: \(cloudPath.path)) called")
		return try await withMainActorSDKContinuation { resumer in
			// Dropbox differs from the filesystem hierarchy standard and accepts instead of "/" only a "".
			// Therefore, `cloudPath` must be checked for the root path and adjusted if necessary.
			let cleanedPath = (cloudPath == CloudPath("/")) ? "" : cloudPath.path
			let task = client.filesRoutes.listFolder(cleanedPath, recursive: nil, includeMediaInfo: nil, includeDeleted: nil, includeHasExplicitSharedMembers: nil, includeMountedFolders: nil, limit: NSNumber(value: self.maxPageSize), sharedLink: nil, includePropertyGroups: nil, includeNonDownloadableFiles: nil)
			task.setResponseBlock { result, routeError, networkError in
				if let routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemList(at: \(cloudPath.path)) failed with routeError: \(routeError)")
					if routeError.isPath(), routeError.path.isNotFound() {
						resumer.resume(throwing: CloudProviderError.itemNotFound)
					} else if routeError.isPath(), routeError.path.isNotFolder() {
						resumer.resume(throwing: CloudProviderError.itemTypeMismatch)
					} else {
						resumer.resume(throwing: DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemList(at: \(cloudPath.path)) failed with networkError: \(networkError)")
					resumer.resume(throwing: self.convertRequestError(networkError))
					return
				}
				guard let result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemList(at: \(cloudPath.path)) failed with missingResult")
					resumer.resume(throwing: DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemList(at: \(cloudPath.path)) received result: \(DBFILESListFolderResult.serialize(result) ?? [:])")
				do {
					try resumer.resume(returning: self.convertDBFILESListFolderResultToCloudItemList(result, at: cloudPath))
				} catch {
					resumer.resume(throwing: error)
				}
			}
		}
	}

	private func fetchItemListContinue(at cloudPath: CloudPath, withPageToken pageToken: String, with client: DBUserClient) async throws -> CloudItemList {
		CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken)) called")
		return try await withMainActorSDKContinuation { resumer in
			let task = client.filesRoutes.listFolderContinue(pageToken)
			task.setResponseBlock { result, routeError, networkError in
				if let routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken)) failed with routeError: \(routeError)")
					if routeError.isPath(), routeError.path.isNotFound() {
						resumer.resume(throwing: CloudProviderError.itemNotFound)
					} else if routeError.isPath(), routeError.path.isNotFolder() {
						resumer.resume(throwing: CloudProviderError.itemTypeMismatch)
					} else if routeError.isReset() {
						resumer.resume(throwing: CloudProviderError.pageTokenInvalid)
					} else {
						resumer.resume(throwing: DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken)) failed with networkError: \(networkError)")
					if networkError.isBadInputError(), let errorContent = networkError.errorContent, errorContent.contains("invalidPageToken") {
						resumer.resume(throwing: CloudProviderError.pageTokenInvalid)
					} else {
						resumer.resume(throwing: self.convertRequestError(networkError))
					}
					return
				}
				guard let result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken)) failed with missingResult")
					resumer.resume(throwing: DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken)) received result: \(DBFILESListFolderResult.serialize(result) ?? [:])")
				do {
					try resumer.resume(returning: self.convertDBFILESListFolderResultToCloudItemList(result, at: cloudPath))
				} catch {
					resumer.resume(throwing: error)
				}
			}
		}
	}

	private func downloadFile(from cloudPath: CloudPath, to localURL: URL, transferProgress: TransferProgress, with client: DBUserClient) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("DropboxCloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) called")
		return try await withMainActorSDKContinuation { resumer in
			let task = client.filesRoutes.downloadUrl(cloudPath.path, overwrite: true, destination: localURL)
			task.setProgressBlock(transferProgress.startAttempt())
			task.setResponseBlock { result, routeError, networkError, _ in
				if let routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) failed with routeError: \(routeError)")
					if routeError.isPath(), routeError.path.isNotFound() {
						resumer.resume(throwing: CloudProviderError.itemNotFound)
					} else if routeError.isPath(), routeError.path.isNotFile() {
						resumer.resume(throwing: CloudProviderError.itemTypeMismatch)
					} else {
						resumer.resume(throwing: DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) failed with networkError: \(networkError)")
					resumer.resume(throwing: self.convertRequestError(networkError))
					return
				}
				guard let result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) failed with missingResult")
					resumer.resume(throwing: DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: downloadFile(from: \(cloudPath.path), to: \(localURL)) finished")
				resumer.resume(returning: self.convertDBFILESFileMetadataToCloudItemMetadata(result, at: cloudPath))
			}
		}
	}

	private func uploadLargeFile(from localURL: URL, to cloudPath: CloudPath, mode: DBFILESWriteMode?, transferProgress: TransferProgress, with client: DBUserClient) async throws -> CloudItemMetadata {
		try await ensureParentFolderExists(for: cloudPath)
		try Task.checkCancellation()
		return try await batchUploadSingleFile(from: localURL, to: cloudPath, mode: mode, transferProgress: transferProgress, with: client)
	}

	private func batchUploadSingleFile(from localURL: URL, to cloudPath: CloudPath, mode: DBFILESWriteMode?, transferProgress: TransferProgress, with client: DBUserClient) async throws -> CloudItemMetadata {
		CloudAccessDDLogDebug("DropboxCloudProvider: batchUploadSingleFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil") called")
		return try await withMainActorSDKContinuation { resumer in
			let commitInfo = DBFILESCommitInfo(path: cloudPath.path, mode: mode, autorename: nil, clientModified: nil, mute: nil, propertyGroups: nil, strictConflict: true)
			client.filesRoutes.batchUploadFiles([localURL: commitInfo], queue: nil, progressBlock: transferProgress.startAttempt()) { fileUrlsToBatchResultEntries, finishBatchRouteError, finishBatchRequestError, fileUrlsToRequestErrors in
				guard let result = fileUrlsToBatchResultEntries?[localURL] else {
					resumer.resume(throwing: self.handleBatchUploadMissingResult(for: localURL, fileUrlsToRequestErrors, finishBatchRouteError, finishBatchRequestError))
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: batchUploadSingleFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) received result: \(DBFILESUploadSessionFinishBatchResultEntry.serialize(result) ?? [:])")
				if result.isFailure() {
					let failure = result.failure
					if failure.isPath(), failure.path.isConflict() {
						resumer.resume(throwing: CloudProviderError.itemAlreadyExists)
					} else if failure.isPath(), failure.path.isInsufficientSpace() {
						resumer.resume(throwing: CloudProviderError.quotaInsufficient)
					} else if failure.isTooManyWriteOperations() {
						resumer.resume(throwing: DropboxError.tooManyWriteOperations)
					} else {
						resumer.resume(throwing: DropboxError.unexpectedResult)
					}
				} else if result.isSuccess() {
					resumer.resume(returning: self.convertDBFILESFileMetadataToCloudItemMetadata(result.success, at: cloudPath))
				} else {
					resumer.resume(throwing: DropboxError.unexpectedResult)
				}
			}
		}
	}

	func handleBatchUploadMissingResult(for localURL: URL, _ fileUrlsToRequestErrors: [URL: DBRequestError], _ finishBatchRouteError: DBASYNCPollError?, _ finishBatchRequestError: DBRequestError?) -> Error {
		if !fileUrlsToRequestErrors.isEmpty {
			CloudAccessDDLogDebug("DropboxCloudProvider: handleBatchUploadMissingResult(for: \(localURL)) failed with fileUrlsToRequestErrors: \(fileUrlsToRequestErrors)")
			guard let requestError = fileUrlsToRequestErrors[localURL] else {
				return DropboxError.unexpectedError
			}
			return convertRequestError(requestError)
		} else if let finishBatchRouteError {
			CloudAccessDDLogDebug("DropboxCloudProvider: handleBatchUploadMissingResult(for: \(localURL)) failed with finishBatchRouteError: \(finishBatchRouteError)")
			return DropboxError.asyncPollError
		} else if let finishBatchRequestError {
			CloudAccessDDLogDebug("DropboxCloudProvider: handleBatchUploadMissingResult(for: \(localURL)) failed with finishBatchRequestError: \(finishBatchRequestError)")
			return convertRequestError(finishBatchRequestError)
		} else {
			CloudAccessDDLogDebug("DropboxCloudProvider: handleBatchUploadMissingResult(for: \(localURL)) failed with missingResult")
			return DropboxError.missingResult
		}
	}

	private func uploadSmallFile(from localURL: URL, to cloudPath: CloudPath, mode: DBFILESWriteMode?, transferProgress: TransferProgress, with client: DBUserClient) async throws -> CloudItemMetadata {
		try await ensureParentFolderExists(for: cloudPath)
		try Task.checkCancellation()
		CloudAccessDDLogDebug("DropboxCloudProvider: uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) called")
		return try await withMainActorSDKContinuation { resumer in
			let task = client.filesRoutes.uploadUrl(cloudPath.path, mode: mode, autorename: nil, clientModified: nil, mute: nil, propertyGroups: nil, strictConflict: true, contentHash: nil, inputUrl: localURL.path)
			task.setProgressBlock(transferProgress.startAttempt())
			task.setResponseBlock { result, routeError, networkError in
				if let routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) failed with routeError: \(routeError)")
					if routeError.isPath(), routeError.path.reason.isConflict() {
						resumer.resume(throwing: CloudProviderError.itemAlreadyExists)
					} else if routeError.isPath(), routeError.path.reason.isInsufficientSpace() {
						resumer.resume(throwing: CloudProviderError.quotaInsufficient)
					} else if routeError.isPath(), routeError.path.reason.isTooManyWriteOperations() {
						resumer.resume(throwing: DropboxError.tooManyWriteOperations)
					} else {
						resumer.resume(throwing: DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) failed with networkError: \(networkError)")
					resumer.resume(throwing: self.convertRequestError(networkError))
					return
				}
				guard let result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) failed with missingResult")
					resumer.resume(throwing: DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode?.description() ?? "nil")) received result: \(DBFILESFileMetadata.serialize(result) ?? [:])")
				resumer.resume(returning: self.convertDBFILESFileMetadataToCloudItemMetadata(result, at: cloudPath))
			}
		}
	}

	private func createFolder(at cloudPath: CloudPath, with client: DBUserClient) async throws {
		try await ensureParentFolderExists(for: cloudPath)
		try Task.checkCancellation()
		CloudAccessDDLogDebug("DropboxCloudProvider: createFolder(at: \(cloudPath.path)) called")
		try await withMainActorSDKContinuation { (resumer: Resumer<Void>) in
			let task = client.filesRoutes.createFolderV2(cloudPath.path)
			task.setResponseBlock { result, routeError, networkError in
				if let routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: createFolder(at: \(cloudPath.path)) failed with routeError: \(routeError)")
					if routeError.isPath(), routeError.path.isConflict() {
						resumer.resume(throwing: CloudProviderError.itemAlreadyExists)
					} else if routeError.isPath(), routeError.path.isInsufficientSpace() {
						resumer.resume(throwing: CloudProviderError.quotaInsufficient)
					} else {
						resumer.resume(throwing: DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: createFolder(at: \(cloudPath.path)) failed with networkError: \(networkError)")
					resumer.resume(throwing: self.convertRequestError(networkError))
					return
				}
				guard let result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: createFolder(at: \(cloudPath.path)) failed with missingResult")
					resumer.resume(throwing: DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: createFolder(at: \(cloudPath.path)) received result: \(DBFILESCreateFolderResult.serialize(result) ?? [:])")
				resumer.resume()
			}
		}
	}

	private func deleteItem(at cloudPath: CloudPath, with client: DBUserClient) async throws {
		CloudAccessDDLogDebug("DropboxCloudProvider: deleteItem(at: \(cloudPath.path)) called")
		try await withMainActorSDKContinuation { (resumer: Resumer<Void>) in
			let task = client.filesRoutes.delete_V2(cloudPath.path)
			task.setResponseBlock { result, routeError, networkError in
				if let routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: deleteItem(at: \(cloudPath.path)) failed with routeError: \(routeError)")
					if routeError.isPathLookup(), routeError.pathLookup.isNotFound() {
						resumer.resume(throwing: CloudProviderError.itemNotFound)
					} else {
						resumer.resume(throwing: DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: deleteItem(at: \(cloudPath.path)) failed with networkError: \(networkError)")
					resumer.resume(throwing: self.convertRequestError(networkError))
					return
				}
				guard let result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: deleteItem(at: \(cloudPath.path)) failed with missingResult")
					resumer.resume(throwing: DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: deleteItem(at: \(cloudPath.path)) received result: \(DBFILESDeleteResult.serialize(result) ?? [:])")
				resumer.resume()
			}
		}
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath, with client: DBUserClient) async throws {
		try await ensureParentFolderExists(for: targetCloudPath)
		try Task.checkCancellation()
		CloudAccessDDLogDebug("DropboxCloudProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) called")
		try await withMainActorSDKContinuation { (resumer: Resumer<Void>) in
			let task = client.filesRoutes.moveV2(sourceCloudPath.path, toPath: targetCloudPath.path)
			task.setResponseBlock { result, routeError, networkError in
				if let routeError {
					CloudAccessDDLogDebug("DropboxCloudProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with routeError: \(routeError)")
					if routeError.isFromLookup(), routeError.fromLookup.isNotFound() {
						resumer.resume(throwing: CloudProviderError.itemNotFound)
					} else if routeError.isTo(), routeError.to.isConflict() {
						resumer.resume(throwing: CloudProviderError.itemAlreadyExists)
					} else if routeError.isTo(), routeError.to.isInsufficientSpace() {
						resumer.resume(throwing: CloudProviderError.quotaInsufficient)
					} else if routeError.isFromWrite(), routeError.fromWrite.isTooManyWriteOperations() {
						resumer.resume(throwing: DropboxError.tooManyWriteOperations)
					} else {
						resumer.resume(throwing: DropboxError.unexpectedRouteError)
					}
					return
				}
				if let networkError {
					CloudAccessDDLogDebug("DropboxCloudProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with networkError: \(networkError)")
					resumer.resume(throwing: self.convertRequestError(networkError))
					return
				}
				guard let result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) failed with missingResult")
					resumer.resume(throwing: DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path)) received result: \(DBFILESRelocationResult.serialize(result) ?? [:])")
				resumer.resume()
			}
		}
	}

	func ensureParentFolderExists(for cloudPath: CloudPath) async throws {
		let parentCloudPath = cloudPath.deletingLastPathComponent()
		if parentCloudPath == CloudPath("/") {
			return
		}
		guard try await checkForItemExistence(at: parentCloudPath) else {
			throw CloudProviderError.parentFolderDoesNotExist
		}
	}

	func retryWithExponentialBackoff<Value>(_ work: () async throws -> Value, condition: (Error) -> Bool) async throws -> Value {
		let attempts = 5
		let exponentialBackoffBase: UInt = 2
		let exponentialBackoffScale = 0.5
		var retryCount = 0
		while true {
			do {
				return try await work()
			} catch {
				guard retryCount < attempts, condition(error) else {
					throw error
				}
				let jitter = Double.random(in: 0 ..< 0.5)
				let sleepTime: Double = if let dropboxError = error as? DropboxError, case let .rateLimitError(retryAfter) = dropboxError {
					Double(retryAfter) + jitter
				} else {
					pow(Double(exponentialBackoffBase), Double(retryCount)) * exponentialBackoffScale + jitter
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: retryWithExponentialBackoff() sleep for \(sleepTime) after error: \(error)")
				try await Task.sleep(for: .seconds(sleepTime))
				retryCount += 1
			}
		}
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
			let clientError = error.asClientError().nsError
			if isCancellationError(clientError) {
				return CancellationError()
			}
			if isNetworkConnectionError(clientError) {
				return CloudProviderError.noInternetConnection
			}
			return DropboxError.clientError
		} else {
			return DropboxError.unexpectedError
		}
	}
}

/// Writes the byte counts of a transfer's current attempt to its progress, so that a retry starts over and late callbacks of an earlier attempt are ignored.
struct TransferProgress: Sendable {
	private let progress: Progress?
	private let currentAttempt = OSAllocatedUnfairLock(initialState: 0)

	init(_ progress: Progress?) {
		self.progress = progress
	}

	func startAttempt() -> DBProgressBlock {
		let attempt = currentAttempt.withLock { currentAttempt in
			currentAttempt += 1
			progress?.completedUnitCount = 0
			return currentAttempt
		}
		return { _, totalBytesTransferred, totalBytesExpectedToTransfer in
			currentAttempt.withLock { currentAttempt in
				guard currentAttempt == attempt else {
					return
				}
				// One unit more than the bytes, because a progress that finished can't be reset for a retry
				progress?.totalUnitCount = totalBytesExpectedToTransfer + 1
				progress?.completedUnitCount = min(totalBytesTransferred, totalBytesExpectedToTransfer)
			}
		}
	}
}
