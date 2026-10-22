//
//  DropboxCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public final class DropboxCloudProvider: CloudProvider {
	/// The most corrected offsets that an upload session accepts while the highest offset that Dropbox confirmed doesn't rise.
	private static let maxStaleOffsetCorrections = 3

	private let client: DropboxClient
	private let maxPageSize: Int
	/// The file size from which an upload goes through an upload session. It defaults to 150 MiB, the most that Dropbox accepts in a single upload.
	private let uploadSessionThreshold: Int
	private let uploadSessionChunkLength: Int

	init(client: DropboxClient, maxPageSize: Int, uploadSessionThreshold: Int = 150 * 1024 * 1024, uploadSessionChunkLength: Int = 24 * 1024 * 1024) {
		self.client = client
		self.maxPageSize = max(1, min(maxPageSize, 2000))
		self.uploadSessionThreshold = uploadSessionThreshold
		self.uploadSessionChunkLength = uploadSessionChunkLength
	}

	public convenience init(credential: DropboxCredential, maxPageSize: Int = .max) {
		self.init(client: .foreground(tokenSource: credential.tokenSource), maxPageSize: maxPageSize)
	}

	/**
	 Creates a Dropbox provider whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.

	 If the provider is used in an app extension, set `DropboxSetup.constants.sharedContainerIdentifier` to a valid identifier for a container that will be shared between the app and the extension.
	 */
	public static func withBackgroundSession(credential: DropboxCredential, maxPageSize: Int = .max, sessionIdentifier: String) -> DropboxCloudProvider {
		return DropboxCloudProvider(client: .background(tokenSource: credential.tokenSource, sessionIdentifier: sessionIdentifier), maxPageSize: maxPageSize)
	}

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		return try await perform("fetchItemMetadata(at: \(cloudPath.path))") {
			try await convertToCloudItemMetadata(client.metadata(path: cloudPath.path), at: cloudPath, untaggedAs: nil)
		}
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		return try await perform("fetchItemList(forFolderAt: \(cloudPath.path), withPageToken: \(pageToken ?? "nil"))") {
			let result: DropboxListFolderResult
			if let pageToken {
				do {
					result = try await client.listFolderContinue(cursor: pageToken)
				} catch DropboxError.apiError(statusCode: 400, _) {
					// Dropbox answers a malformed cursor with 400.
					throw CloudProviderError.pageTokenInvalid
				}
			} else {
				// Dropbox lists the root at "" instead of "/".
				result = try await client.listFolder(path: cloudPath == CloudPath("/") ? "" : cloudPath.path, limit: maxPageSize)
			}
			let items = try result.entries.map { entry in
				try convertToCloudItemMetadata(entry, at: cloudPath.appendingPathComponent(entry.name), untaggedAs: nil)
			}
			return CloudItemList(items: items, nextPageToken: result.hasMore ? result.cursor : nil)
		}
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		let phases = Progress.phases(of: progress, 999)
		let metadata = try await perform("downloadFile(from: \(cloudPath.path), to: \(localURL))") {
			try await DownloadOperation.download(to: localURL, transfer: { stagedFile in
				let file = try await client.download(path: cloudPath.path, to: stagedFile, progress: phases[0], onTaskCreation: onTaskCreation)
				return try convertToCloudItemMetadata(file, at: cloudPath, untaggedAs: .file)
			})
		}
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
		let mode: DropboxClient.WriteMode = replaceExisting ? .overwrite : .add
		let fileSize = attributes[FileAttributeKey.size] as? Int ?? uploadSessionThreshold
		let metadata = try await perform("uploadFile(from: \(localURL), to: \(cloudPath.path), mode: \(mode), fileSize: \(fileSize))") {
			try await ensureParentFolderExists(for: cloudPath)
			try Task.checkCancellation()
			let file = if fileSize >= uploadSessionThreshold {
				try await uploadLargeFile(from: localURL, to: cloudPath, mode: mode, fileSize: Int64(fileSize), progress: phases[0])
			} else {
				try await client.upload(from: localURL, path: cloudPath.path, mode: mode, progress: phases[0], onTaskCreation: onTaskCreation)
			}
			return try convertToCloudItemMetadata(file, at: cloudPath, untaggedAs: .file)
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
		try await perform("createFolder(at: \(cloudPath.path))") {
			try await ensureParentFolderExists(for: cloudPath)
			try Task.checkCancellation()
			try await withoutCancellation {
				try await self.client.createFolder(path: cloudPath.path)
			}
		}
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

	/**
	 - Warning: This function is not atomic, because the existence of the parentFolder of the target must be checked, otherwise Dropbox creates the missing folders automatically.
	 */
	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	/**
	 - Warning: This function is not atomic, because the existence of the parentFolder of the target must be checked, otherwise Dropbox creates the missing folders automatically.
	 */
	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		try await moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	// MARK: - Operations

	private func deleteItem(at cloudPath: CloudPath) async throws {
		try await perform("deleteItem(at: \(cloudPath.path))") {
			try await withoutCancellation {
				try await self.client.delete(path: cloudPath.path)
			}
		}
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try await perform("moveItem(from: \(sourceCloudPath.path), to: \(targetCloudPath.path))") {
			try await ensureParentFolderExists(for: targetCloudPath)
			try Task.checkCancellation()
			try await withoutCancellation {
				try await self.client.move(from: sourceCloudPath.path, to: targetCloudPath.path)
			}
		}
	}

	/**
	 Uploads the file through an upload session, one chunk after the other, each from a temporary file, so that no chunk is held in memory. The progress counts bytes, and each chunk gets a share of its length.

	 An append that Dropbox rejects for its offset continues from the offset that Dropbox expects. The upload gives up after more than `maxStaleOffsetCorrections` corrections since the highest confirmed offset last rose, or for an expected offset outside the file.
	 */
	private func uploadLargeFile(from localURL: URL, to cloudPath: CloudPath, mode: DropboxClient.WriteMode, fileSize: Int64, progress: Progress?) async throws -> DropboxMetadata {
		progress?.totalUnitCount = fileSize
		let sessionID = try await client.startUploadSession()
		let fileHandle = try FileHandle(forReadingFrom: localURL)
		defer {
			try? fileHandle.close()
		}
		var offset: Int64 = 0
		var highestConfirmedOffset: Int64 = 0
		var staleCorrectionCount = 0
		var sentLength: Int64 = 0
		while offset < fileSize {
			try Task.checkCancellation()
			let (chunkFileURL, writtenLength) = try writeChunk(of: fileHandle, at: offset, length: min(Int64(uploadSessionChunkLength), fileSize - offset))
			defer {
				try? FileManager.default.removeItem(at: chunkFileURL)
			}
			let chunkProgress = progress?.makeExplicitChild(pendingUnitCount: writtenLength)
			sentLength += writtenLength
			if let correctOffset = try await client.appendToUploadSession(sessionID: sessionID, offset: offset, from: chunkFileURL, progress: chunkProgress) {
				guard (0 ... fileSize).contains(correctOffset) else {
					throw DropboxError.unexpectedContent
				}
				if correctOffset > highestConfirmedOffset {
					highestConfirmedOffset = correctOffset
					staleCorrectionCount = 0
				} else {
					staleCorrectionCount += 1
					guard staleCorrectionCount <= DropboxCloudProvider.maxStaleOffsetCorrections else {
						throw DropboxError.unexpectedContent
					}
				}
				offset = correctOffset
				// The bytes from the new offset are sent again, on top of those sent so far.
				progress?.totalUnitCount = sentLength + fileSize - offset
			} else {
				offset += writtenLength
				if offset > highestConfirmedOffset {
					highestConfirmedOffset = offset
					staleCorrectionCount = 0
				}
			}
		}
		try Task.checkCancellation()
		// The commit creates the file, so it runs to its end, with its retries, even if the task is cancelled meanwhile.
		return try await withoutCancellation { [offset] in
			try await self.client.finishUploadSession(sessionID: sessionID, offset: offset, path: cloudPath.path, mode: mode)
		}
	}

	/**
	 Copies a chunk of the file into a temporary file, which the caller deletes.

	 - Returns: The temporary file and the length of the chunk.
	 */
	private func writeChunk(of fileHandle: FileHandle, at offset: Int64, length: Int64) throws -> (URL, Int64) {
		try fileHandle.seek(toOffset: UInt64(offset))
		var writtenLength: Int64 = 0
		let chunkFileURL = try HTTPClientSupport.writeTemporaryFile { chunkHandle in
			while writtenLength < length, let data = try fileHandle.read(upToCount: Int(min(Int64(HTTPClientSupport.temporaryFileBufferLength), length - writtenLength))), !data.isEmpty {
				try chunkHandle.write(contentsOf: data)
				writtenLength += Int64(data.count)
			}
		}
		guard writtenLength > 0 else {
			// The file got shorter during the upload.
			try? FileManager.default.removeItem(at: chunkFileURL)
			throw DropboxError.unexpectedContent
		}
		return (chunkFileURL, writtenLength)
	}

	// MARK: - Helpers

	/// Logs the operation and converts the errors that it throws.
	private func perform<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
		CloudAccessDDLogDebug("DropboxCloudProvider: \(operation) called")
		do {
			return try await body()
		} catch {
			CloudAccessDDLogDebug("DropboxCloudProvider: \(operation) failed with error: \(error)")
			throw convertStandardError(error)
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

	/// Dropbox reports no size or date for a folder.
	private func convertToCloudItemMetadata(_ metadata: DropboxMetadata, at cloudPath: CloudPath, untaggedAs untaggedType: CloudItemType?) throws -> CloudItemMetadata {
		switch try metadata.cloudItemType(untaggedAs: untaggedType) {
		case .folder:
			return CloudItemMetadata(name: metadata.name, cloudPath: cloudPath, itemType: .folder, lastModifiedDate: nil, size: nil)
		default:
			guard let size = metadata.size else {
				throw DropboxError.unexpectedContent
			}
			return try CloudItemMetadata(name: metadata.name, cloudPath: cloudPath, itemType: .file, lastModifiedDate: metadata.lastModifiedDate, size: Int(size))
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

	/// Maps an unauthorized request and the route errors of a 409, whose `error_summary` starts with the tags of the route's argument, e.g., `path_lookup/not_found/..` for a missing item to delete.
	func convertStandardError(_ error: Error) -> Error {
		guard case let DropboxError.apiError(statusCode, summary) = error else {
			return error
		}
		if statusCode == 401 {
			return CloudProviderError.unauthorized
		}
		guard statusCode == 409 else {
			return error
		}
		let tags = DropboxErrorResponse.tags(of: summary)
		switch (tags.first ?? "", tags.dropFirst().first ?? "") {
		case ("path", "not_found"), ("path_lookup", "not_found"), ("from_lookup", "not_found"):
			return CloudProviderError.itemNotFound
		case ("path", "not_file"), ("path", "not_folder"), ("path_lookup", "not_file"), ("path_lookup", "not_folder"), ("from_lookup", "not_file"), ("from_lookup", "not_folder"):
			return CloudProviderError.itemTypeMismatch
		case ("path", "conflict"), ("path_write", "conflict"), ("from_write", "conflict"), ("to", "conflict"):
			return CloudProviderError.itemAlreadyExists
		case ("path", "insufficient_space"), ("path_write", "insufficient_space"), ("from_write", "insufficient_space"), ("to", "insufficient_space"), ("insufficient_quota", _):
			return CloudProviderError.quotaInsufficient
		case ("reset", _):
			return CloudProviderError.pageTokenInvalid
		default:
			return error
		}
	}
}
