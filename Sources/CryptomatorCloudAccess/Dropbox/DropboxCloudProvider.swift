//
//  DropboxCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
@preconcurrency import SwiftyDropbox

public final class DropboxCloudProvider: CloudProvider {
	/// Dropbox accepts at most 150 MiB in a single upload.
	private static let uploadSessionThreshold = 150 * 1024 * 1024
	private static let uploadSessionChunkLength = 8 * 1024 * 1024

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
			try await fetchItemMetadata(at: cloudPath, with: authorizedClient.client)
		}, condition: shouldRetryForError)
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		return try await retryWithExponentialBackoff({
			try await fetchItemList(at: cloudPath, withPageToken: pageToken, with: authorizedClient.client)
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
				try await downloadFile(from: cloudPath, to: stagedFile, transferProgress: transferProgress, with: authorizedClient.transferClient)
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
		let mode: Files.WriteMode = replaceExisting ? .overwrite : .add
		let fileSize = attributes[FileAttributeKey.size] as? Int ?? DropboxCloudProvider.uploadSessionThreshold
		let metadata = if fileSize >= DropboxCloudProvider.uploadSessionThreshold {
			try await uploadLargeFile(from: localURL, to: cloudPath, mode: mode, transferProgress: transferProgress, with: authorizedClient.client)
		} else {
			try await retryWithExponentialBackoff({
				try await uploadSmallFile(from: localURL, to: cloudPath, mode: mode, transferProgress: transferProgress, with: authorizedClient.transferClient)
			}, condition: shouldRetryForError)
		}
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
			try await createFolder(at: cloudPath, with: authorizedClient.client)
		}, condition: shouldRetryForError)
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		try await retryWithExponentialBackoff({
			try await deleteItem(at: cloudPath, with: authorizedClient.client)
		}, condition: shouldRetryForError)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		guard let authorizedClient = credential.authorizedClient else {
			throw CloudProviderError.unauthorized
		}
		try await retryWithExponentialBackoff({
			try await deleteItem(at: cloudPath, with: authorizedClient.client)
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
			try await moveItem(from: sourceCloudPath, to: targetCloudPath, with: authorizedClient.client)
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
			try await moveItem(from: sourceCloudPath, to: targetCloudPath, with: authorizedClient.client)
		}, condition: shouldRetryForError)
	}

	// MARK: - Dropbox Operations

	private func fetchItemMetadata(at cloudPath: CloudPath, with client: DropboxClient) async throws -> CloudItemMetadata {
		return try await send("fetchItemMetadata(at: \(cloudPath.path))", {
			client.files.getMetadata(path: cloudPath.path)
		}, convertRouteError: { routeError in
			switch routeError {
			case let .path(lookupError):
				return self.convertLookupError(lookupError)
			}
		}, convertResult: { result in
			try self.convertMetadataToCloudItemMetadata(result, at: cloudPath)
		})
	}

	private func fetchItemList(at cloudPath: CloudPath, withPageToken pageToken: String?, with client: DropboxClient) async throws -> CloudItemList {
		if let pageToken {
			return try await fetchItemListContinue(at: cloudPath, withPageToken: pageToken, with: client)
		} else {
			return try await fetchItemList(at: cloudPath, with: client)
		}
	}

	private func fetchItemList(at cloudPath: CloudPath, with client: DropboxClient) async throws -> CloudItemList {
		// Dropbox differs from the filesystem hierarchy standard and accepts instead of "/" only a "".
		// Therefore, `cloudPath` must be checked for the root path and adjusted if necessary.
		let cleanedPath = (cloudPath == CloudPath("/")) ? "" : cloudPath.path
		return try await send("fetchItemList(at: \(cloudPath.path))", {
			client.files.listFolder(path: cleanedPath, limit: UInt32(self.maxPageSize))
		}, convertRouteError: { routeError in
			switch routeError {
			case let .path(lookupError):
				return self.convertLookupError(lookupError)
			default:
				return nil
			}
		}, convertResult: { result in
			try self.convertListFolderResultToCloudItemList(result, at: cloudPath)
		})
	}

	private func fetchItemListContinue(at cloudPath: CloudPath, withPageToken pageToken: String, with client: DropboxClient) async throws -> CloudItemList {
		return try await send("fetchItemListContinue(at: \(cloudPath.path), withPageToken: \(pageToken))", {
			client.files.listFolderContinue(cursor: pageToken)
		}, convertRouteError: { routeError in
			switch routeError {
			case let .path(lookupError):
				return self.convertLookupError(lookupError)
			case .reset:
				return CloudProviderError.pageTokenInvalid
			default:
				return nil
			}
		}, convertResult: { result in
			try self.convertListFolderResultToCloudItemList(result, at: cloudPath)
		})
	}

	private func downloadFile(from cloudPath: CloudPath, to localURL: URL, transferProgress: TransferProgress, with client: DropboxClient) async throws -> CloudItemMetadata {
		return try await send("downloadFile(from: \(cloudPath.path), to: \(localURL))", {
			let reportProgress = transferProgress.startAttempt()
			return client.files.download(path: cloudPath.path, overwrite: true, destination: localURL).progress { progress in
				reportProgress(progress.completedUnitCount, progress.totalUnitCount)
			}
		}, convertRouteError: { routeError in
			switch routeError {
			case let .path(lookupError):
				return self.convertLookupError(lookupError)
			default:
				return nil
			}
		}, convertResult: { result in
			let (fileMetadata, _) = result
			return self.convertFileMetadataToCloudItemMetadata(fileMetadata, at: cloudPath)
		})
	}

	private func uploadLargeFile(from localURL: URL, to cloudPath: CloudPath, mode: Files.WriteMode, transferProgress: TransferProgress, with client: DropboxClient) async throws -> CloudItemMetadata {
		try await ensureParentFolderExists(for: cloudPath)
		try Task.checkCancellation()
		CloudAccessDDLogDebug("DropboxCloudProvider: uploadLargeFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode)) called")
		let fileHandle = try FileHandle(forReadingFrom: localURL)
		defer {
			try? fileHandle.close()
		}
		let fileSize = try fileHandle.seekToEnd()
		try fileHandle.seek(toOffset: 0)
		let reportProgress = transferProgress.startAttempt()
		let sessionID = try await retryWithExponentialBackoff({
			try await startUploadSession(with: client)
		}, condition: shouldRetryForError)
		var offset: UInt64 = 0
		while let chunk = try fileHandle.read(upToCount: DropboxCloudProvider.uploadSessionChunkLength), !chunk.isEmpty {
			try Task.checkCancellation()
			let cursor = Files.UploadSessionCursor(sessionId: sessionID, offset: offset)
			try await retryWithExponentialBackoff({
				try await appendToUploadSession(at: cursor, chunk: chunk, with: client)
			}, condition: shouldRetryForError)
			offset += UInt64(chunk.count)
			reportProgress(Int64(offset), Int64(fileSize))
		}
		try Task.checkCancellation()
		let cursor = Files.UploadSessionCursor(sessionId: sessionID, offset: offset)
		let commit = Files.CommitInfo(path: cloudPath.path, mode: mode, strictConflict: true)
		return try await retryWithExponentialBackoff({
			try await finishUploadSession(at: cursor, commit: commit, to: cloudPath, with: client)
		}, condition: shouldRetryForError)
	}

	private func startUploadSession(with client: DropboxClient) async throws -> String {
		return try await send("startUploadSession()", {
			client.files.uploadSessionStart(input: Data())
		}, convertResult: { result in
			result.sessionId
		})
	}

	private func appendToUploadSession(at cursor: Files.UploadSessionCursor, chunk: Data, with client: DropboxClient) async throws {
		try await send("appendToUploadSession(at: \(cursor))", {
			client.files.uploadSessionAppendV2(cursor: cursor, input: chunk)
		}, convertResult: { _ in })
	}

	private func finishUploadSession(at cursor: Files.UploadSessionCursor, commit: Files.CommitInfo, to cloudPath: CloudPath, with client: DropboxClient) async throws -> CloudItemMetadata {
		return try await send("finishUploadSession(at: \(cursor), to: \(cloudPath.path))", {
			client.files.uploadSessionFinish(cursor: cursor, commit: commit, input: Data())
		}, convertRouteError: { routeError in
			switch routeError {
			case let .path(writeError):
				return self.convertWriteError(writeError)
			case .tooManyWriteOperations:
				return DropboxError.tooManyWriteOperations
			default:
				return nil
			}
		}, convertResult: { result in
			self.convertFileMetadataToCloudItemMetadata(result, at: cloudPath)
		})
	}

	private func uploadSmallFile(from localURL: URL, to cloudPath: CloudPath, mode: Files.WriteMode, transferProgress: TransferProgress, with client: DropboxClient) async throws -> CloudItemMetadata {
		try await ensureParentFolderExists(for: cloudPath)
		try Task.checkCancellation()
		return try await send("uploadSmallFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode))", {
			let reportProgress = transferProgress.startAttempt()
			return client.files.upload(path: cloudPath.path, mode: mode, strictConflict: true, input: localURL).progress { progress in
				reportProgress(progress.completedUnitCount, progress.totalUnitCount)
			}
		}, convertRouteError: { routeError in
			switch routeError {
			case let .path(uploadWriteFailed):
				return self.convertWriteError(uploadWriteFailed.reason)
			default:
				return nil
			}
		}, convertResult: { result in
			self.convertFileMetadataToCloudItemMetadata(result, at: cloudPath)
		})
	}

	private func createFolder(at cloudPath: CloudPath, with client: DropboxClient) async throws {
		try await ensureParentFolderExists(for: cloudPath)
		try Task.checkCancellation()
		try await send("createFolder(at: \(cloudPath.path))", {
			client.files.createFolderV2(path: cloudPath.path)
		}, convertRouteError: { routeError in
			switch routeError {
			case let .path(writeError):
				return self.convertWriteError(writeError)
			}
		}, convertResult: { _ in })
	}

	private func deleteItem(at cloudPath: CloudPath, with client: DropboxClient) async throws {
		try await send("deleteItem(at: \(cloudPath.path))", {
			client.files.deleteV2(path: cloudPath.path)
		}, convertRouteError: { routeError in
			switch routeError {
			case let .pathLookup(lookupError):
				return self.convertLookupError(lookupError)
			case let .pathWrite(writeError):
				return self.convertWriteError(writeError)
			case .tooManyWriteOperations:
				return DropboxError.tooManyWriteOperations
			default:
				return nil
			}
		}, convertResult: { _ in })
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath, with client: DropboxClient) async throws {
		try await ensureParentFolderExists(for: targetCloudPath)
		try Task.checkCancellation()
		try await send("moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path))", {
			client.files.moveV2(fromPath: sourceCloudPath.path, toPath: targetCloudPath.path)
		}, convertRouteError: { routeError in
			switch routeError {
			case let .fromLookup(lookupError):
				return self.convertLookupError(lookupError)
			case let .fromWrite(writeError), let .to(writeError):
				return self.convertWriteError(writeError)
			default:
				return nil
			}
		}, convertResult: { _ in })
	}

	/// Issues the request on the main actor and converts its result, or its error with `convertRouteError` for the route errors that it can map.
	private func send<Request: HasRequestResponse & SendableMetatype, Value: Sendable>(_ operation: String, _ makeRequest: @escaping @Sendable () -> Request, convertRouteError: @escaping @Sendable (Request.ESerial.ValueType) -> Error? = { _ in nil }, convertResult: @escaping @Sendable (Request.ValueType) throws -> Value) async throws -> Value {
		CloudAccessDDLogDebug("DropboxCloudProvider: \(operation) called")
		return try await withMainActorSDKContinuation { resumer in
			makeRequest().response(queue: nil) { result, error in
				if let error {
					CloudAccessDDLogDebug("DropboxCloudProvider: \(operation) failed with error: \(error)")
					resumer.resume(throwing: error.converted(convertRouteError: convertRouteError))
					return
				}
				guard let result else {
					CloudAccessDDLogDebug("DropboxCloudProvider: \(operation) failed with missingResult")
					resumer.resume(throwing: DropboxError.missingResult)
					return
				}
				CloudAccessDDLogDebug("DropboxCloudProvider: \(operation) received result: \(result)")
				do {
					try resumer.resume(returning: convertResult(result))
				} catch {
					resumer.resume(throwing: error)
				}
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

	func convertMetadataToCloudItemMetadata(_ metadata: Files.Metadata, at cloudPath: CloudPath) throws -> CloudItemMetadata {
		if metadata is Files.FolderMetadata {
			return CloudItemMetadata(name: metadata.name, cloudPath: cloudPath, itemType: .folder, lastModifiedDate: nil, size: nil)
		}
		guard let fileMetadata = metadata as? Files.FileMetadata else {
			throw DropboxError.unexpectedResult
		}
		return convertFileMetadataToCloudItemMetadata(fileMetadata, at: cloudPath)
	}

	func convertFileMetadataToCloudItemMetadata(_ metadata: Files.FileMetadata, at cloudPath: CloudPath) -> CloudItemMetadata {
		return CloudItemMetadata(name: metadata.name, cloudPath: cloudPath, itemType: .file, lastModifiedDate: metadata.serverModified, size: Int(metadata.size))
	}

	func convertListFolderResultToCloudItemList(_ folderResult: Files.ListFolderResult, at cloudPath: CloudPath) throws -> CloudItemList {
		var items = [CloudItemMetadata]()
		for metadata in folderResult.entries {
			let itemCloudPath = cloudPath.appendingPathComponent(metadata.name)
			let itemMetadata = try convertMetadataToCloudItemMetadata(metadata, at: itemCloudPath)
			items.append(itemMetadata)
		}
		let nextPageToken = folderResult.hasMore ? folderResult.cursor : nil
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

	func convertLookupError(_ error: Files.LookupError) -> Error? {
		switch error {
		case .notFound:
			return CloudProviderError.itemNotFound
		case .notFile, .notFolder:
			return CloudProviderError.itemTypeMismatch
		default:
			return nil
		}
	}

	func convertWriteError(_ error: Files.WriteError) -> Error? {
		switch error {
		case .conflict:
			return CloudProviderError.itemAlreadyExists
		case .insufficientSpace:
			return CloudProviderError.quotaInsufficient
		case .tooManyWriteOperations:
			return DropboxError.tooManyWriteOperations
		default:
			return nil
		}
	}
}

extension CallError {
	/// Converts the error, using `convertRouteError` for the route errors that it can map. A route error that it returns `nil` for becomes `DropboxError.unexpectedRouteError`.
	// swiftlint:disable:next cyclomatic_complexity
	func converted(convertRouteError: (EType) -> Error? = { _ in nil }) -> Error {
		switch self {
		case let .routeError(routeError, _, _, _):
			return convertRouteError(routeError.unboxed) ?? DropboxError.unexpectedRouteError
		case .httpError:
			return DropboxError.httpError
		case let .badInputError(message?, _) where message.contains("invalidPageToken"):
			return CloudProviderError.pageTokenInvalid
		case .badInputError:
			return DropboxError.badInputError
		case .authError:
			return CloudProviderError.unauthorized
		case .accessError:
			return DropboxError.accessError
		case let .rateLimitError(rateLimitError, _, _, _):
			return DropboxError.rateLimitError(retryAfter: Int(rateLimitError.retryAfter))
		case .internalServerError:
			return DropboxError.internalServerError
		case let .clientError(.urlSessionError(error)) where isCancellationError(error):
			return CancellationError()
		case let .clientError(.urlSessionError(error)) where isNetworkConnectionError(error):
			return CloudProviderError.noInternetConnection
		case .clientError:
			return DropboxError.clientError
		case .serializationError, .reconnectionError:
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

	func startAttempt() -> @Sendable (_ totalBytesTransferred: Int64, _ totalBytesExpectedToTransfer: Int64) -> Void {
		let attempt = currentAttempt.withLock { currentAttempt in
			currentAttempt += 1
			progress?.completedUnitCount = 0
			return currentAttempt
		}
		return { totalBytesTransferred, totalBytesExpectedToTransfer in
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
