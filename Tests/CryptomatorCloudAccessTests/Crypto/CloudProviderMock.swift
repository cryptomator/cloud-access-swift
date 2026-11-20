//
//  CloudProviderMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

/// `@unchecked Sendable`: `folders`, `files`, `maxPageSize`, `rejectsExistingItems`, `aliases`, `aliasedDownloads` and `lastModifiedDate` are immutable, everything else is protected by `state`. The class is subclassed by the vault format mocks.
public class CloudProviderMock: CloudProvider, @unchecked Sendable {
	private struct State {
		var calls: [String] = []
		var createdFolders: [String] = []
		var createdFiles: [String: Data] = [:]
		var deleted: [String] = []
		var moved: [String: String] = [:]
		var transferHook: (@Sendable (CloudPath, Progress?) async throws -> Void)?
		var mutationHook: (@Sendable () -> Void)?
		var metadataHook: (@Sendable (CloudPath) throws -> Void)?
		var metadataOverride: (@Sendable (CloudPath) throws -> CloudItemMetadata?)?
		var moveHook: (@Sendable () throws -> Void)?
		var listingHook: (@Sendable (CloudPath, String?) throws -> Void)?
		var afterMutationHook: (@Sendable (String, CloudPath) throws -> Void)?
	}

	let folders: Set<String>
	let files: [String: Data]
	let maxPageSize: Int
	/// Whether creating a folder at a fixture folder or file, or uploading to a fixture file without `replaceExisting`, throws `itemAlreadyExists`, as with a real provider. Created, deleted and moved items don't count.
	let rejectsExistingItems: Bool
	/// The paths of the fixture items that a listing marks as aliases, as a provider marks a shortcut. Metadata reads and downloads don't mark them (see `aliasedDownloads`).
	let aliases: Set<String>
	/// The paths of the fixture files whose download reports an alias, as Google Drive and Microsoft Graph do when the path, or the folder that holds it, resolves to one.
	let aliasedDownloads: Set<String>
	let lastModifiedDate = Date(timeIntervalSinceReferenceDate: 0)
	private let state = OSAllocatedUnfairLock(initialState: State())

	/// The names of the methods called so far, also of a call that then threw `CancellationError` because its task was cancelled.
	var calls: [String] {
		state.withLock { $0.calls }
	}

	var createdFolders: [String] {
		state.withLock { $0.createdFolders }
	}

	var createdFiles: [String: Data] {
		state.withLock { $0.createdFiles }
	}

	var deleted: [String] {
		state.withLock { $0.deleted }
	}

	var moved: [String: String] {
		state.withLock { $0.moved }
	}

	/// Runs while a download or an upload of the given cloud path is in flight, with the progress of its bytes.
	var transferHook: (@Sendable (CloudPath, Progress?) async throws -> Void)? {
		get { state.withLock { $0.transferHook } }
		set { state.withLock { $0.transferHook = newValue } }
	}

	/// Runs after each upload, folder creation, deletion and move took effect.
	var mutationHook: (@Sendable () -> Void)? {
		get { state.withLock { $0.mutationHook } }
		set { state.withLock { $0.mutationHook = newValue } }
	}

	/// Runs before the metadata of an item is fetched, which fails with the error that the hook throws.
	var metadataHook: (@Sendable (CloudPath) throws -> Void)? {
		get { state.withLock { $0.metadataHook } }
		set { state.withLock { $0.metadataHook = newValue } }
	}

	/// Runs after `metadataHook` and returns the metadata of an item instead of the fixture, which it falls back to for `nil`. An error that it throws fails the call.
	var metadataOverride: (@Sendable (CloudPath) throws -> CloudItemMetadata?)? {
		get { state.withLock { $0.metadataOverride } }
		set { state.withLock { $0.metadataOverride = newValue } }
	}

	/// Runs before a file is moved, which fails with the error that the hook throws.
	var moveHook: (@Sendable () throws -> Void)? {
		get { state.withLock { $0.moveHook } }
		set { state.withLock { $0.moveHook = newValue } }
	}

	/// Runs before a page of the given folder is listed, with its page token, which fails with the error that the hook throws.
	var listingHook: (@Sendable (CloudPath, String?) throws -> Void)? {
		get { state.withLock { $0.listingHook } }
		set { state.withLock { $0.listingHook = newValue } }
	}

	/// Runs after a deletion or a move took effect, with the name of the call and its cloud path (a move's source). The call then fails with the error that the hook throws.
	var afterMutationHook: (@Sendable (String, CloudPath) throws -> Void)? {
		get { state.withLock { $0.afterMutationHook } }
		set { state.withLock { $0.afterMutationHook = newValue } }
	}

	/// Returns an `afterMutationHook` that fails the call of the given name with the error at the given cloud paths, or at every path if `paths` is empty.
	static func failing(_ call: String, with error: Error, at paths: Set<String> = []) -> @Sendable (String, CloudPath) throws -> Void {
		return { mutation, cloudPath in
			if mutation == call, paths.isEmpty || paths.contains(cloudPath.path) {
				throw error
			}
		}
	}

	/// Returns a `metadataOverride` that answers the reads of the given cloud path with the given item types in order, repeating the last one. A `nil` type answers with `CloudProviderError.itemNotFound`. Other cloud paths fall back to the fixture.
	static func reading(_ itemTypes: [CloudItemType?], at path: String) -> @Sendable (CloudPath) throws -> CloudItemMetadata? {
		let readCount = OSAllocatedUnfairLock(initialState: 0)
		return { cloudPath in
			guard cloudPath.path == path else {
				return nil
			}
			let index = readCount.withLock { count in
				defer { count += 1 }
				return min(count, itemTypes.count - 1)
			}
			guard let itemType = itemTypes[index] else {
				throw CloudProviderError.itemNotFound
			}
			return CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: nil, size: nil)
		}
	}

	/// Returns a `listingHook` that records the listed folders and fails the listing of a folder that was listed before, so that a delete that loops ends.
	static func listingEachFolderOnce(recordingInto listedFolders: OSAllocatedUnfairLock<[String]>) -> @Sendable (CloudPath, String?) throws -> Void {
		return { cloudPath, pageToken in
			guard pageToken == nil else {
				return
			}
			let isListedBefore = listedFolders.withLock { listedFolders in
				defer { listedFolders.append(cloudPath.path) }
				return listedFolders.contains(cloudPath.path)
			}
			if isListedBefore {
				throw CloudProviderError.quotaInsufficient
			}
		}
	}

	/// Replaces `listingHook` and `transferHook` with hooks that record the paths of the listed folders and of the transferred files.
	func recordingListingsAndTransfers() -> (listedFolders: OSAllocatedUnfairLock<[String]>, transferredFiles: OSAllocatedUnfairLock<[String]>) {
		let listedFolders = OSAllocatedUnfairLock(initialState: [String]())
		let transferredFiles = OSAllocatedUnfairLock(initialState: [String]())
		listingHook = { cloudPath, _ in
			listedFolders.withLock { $0.append(cloudPath.path) }
		}
		transferHook = { cloudPath, _ in
			transferredFiles.withLock { $0.append(cloudPath.path) }
		}
		return (listedFolders, transferredFiles)
	}

	init(folders: Set<String>, files: [String: Data], maxPageSize: Int = .max, rejectsExistingItems: Bool = false, aliases: Set<String> = [], aliasedDownloads: Set<String> = []) {
		self.folders = folders
		self.files = files
		self.maxPageSize = maxPageSize
		self.rejectsExistingItems = rejectsExistingItems
		self.aliases = aliases
		self.aliasedDownloads = aliasedDownloads
	}

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		record("fetchItemMetadata")
		try Task.checkCancellation()
		try metadataHook?(cloudPath)
		if let metadata = try metadataOverride?(cloudPath) {
			return metadata
		}
		return try getItemMetadata(at: cloudPath)
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		record("fetchItemList")
		try Task.checkCancellation()
		try listingHook?(cloudPath, pageToken)
		if files[cloudPath.path] != nil {
			throw CloudProviderError.itemTypeMismatch
		}
		let parentPath = cloudPath.path
		let parentPathLvl = parentPath.components(separatedBy: "/").count
		let childDirs = folders.filter { $0.hasPrefix(parentPath) && $0.components(separatedBy: "/").count == parentPathLvl + 1 }
		let childFiles = files.keys.filter { $0.hasPrefix(parentPath) && $0.components(separatedBy: "/").count == parentPathLvl + 1 }
		let children = (childDirs + childFiles).sorted()
		let pageStart = pageToken.flatMap(Int.init) ?? 0
		let page = children.dropFirst(pageStart).prefix(maxPageSize)
		let nextPageStart = pageStart + page.count
		let items = try page.map { path in
			let metadata = try getItemMetadata(at: CloudPath(path))
			return CloudItemMetadata(name: metadata.name, cloudPath: metadata.cloudPath, itemType: metadata.itemType, lastModifiedDate: metadata.lastModifiedDate, size: metadata.size, isAlias: aliases.contains(path))
		}
		return CloudItemList(items: items, nextPageToken: nextPageStart < children.count ? String(nextPageStart) : nil)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		record("downloadFile")
		try Task.checkCancellation()
		guard let data = files[cloudPath.path] else {
			throw CloudProviderError.itemNotFound
		}
		let phases = Progress.phases(of: progress, 999)
		try await transferHook?(cloudPath, phases[0])
		try data.write(to: localURL, options: .withoutOverwriting)
		phases.completeTransfer()
		return CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .file, lastModifiedDate: lastModifiedDate, size: data.count, isAlias: aliasedDownloads.contains(cloudPath.path))
	}

	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		record("uploadFile")
		try Task.checkCancellation()
		if rejectsExistingItems, !replaceExisting, files[cloudPath.path] != nil {
			throw CloudProviderError.itemAlreadyExists
		}
		let data = try Data(contentsOf: localURL)
		let phases = Progress.phases(of: progress, 999)
		try await transferHook?(cloudPath, phases[0])
		state.withLock { $0.createdFiles[cloudPath.path] = data }
		mutationHook?()
		phases.completeTransfer()
		return CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .file, lastModifiedDate: lastModifiedDate, size: data.count)
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		record("createFolder")
		try Task.checkCancellation()
		if rejectsExistingItems, folders.contains(cloudPath.path) || files[cloudPath.path] != nil {
			throw CloudProviderError.itemAlreadyExists
		}
		state.withLock { $0.createdFolders.append(cloudPath.path) }
		mutationHook?()
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		record("deleteFile")
		try Task.checkCancellation()
		deleteItem(at: cloudPath)
		try afterMutationHook?("deleteFile", cloudPath)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		record("deleteFolder")
		try Task.checkCancellation()
		if files[cloudPath.path] != nil, !deleted.contains(cloudPath.path) {
			throw CloudProviderError.itemTypeMismatch
		}
		guard !deleted.contains(cloudPath.path), folders.contains(cloudPath.path) || createdFolders.contains(cloudPath.path) else {
			throw CloudProviderError.itemNotFound
		}
		deleteItem(at: cloudPath)
		try afterMutationHook?("deleteFolder", cloudPath)
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		record("moveFile")
		try Task.checkCancellation()
		try moveHook?()
		moveItem(from: sourceCloudPath, to: targetCloudPath)
		try afterMutationHook?("moveFile", sourceCloudPath)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		record("moveFolder")
		try Task.checkCancellation()
		moveItem(from: sourceCloudPath, to: targetCloudPath)
		try afterMutationHook?("moveFolder", sourceCloudPath)
	}

	private func record(_ call: String) {
		state.withLock { $0.calls.append(call) }
	}

	private func getItemMetadata(at cloudPath: CloudPath) throws -> CloudItemMetadata {
		if folders.contains(cloudPath.path) {
			return CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .folder, lastModifiedDate: lastModifiedDate, size: 0)
		} else if let data = files[cloudPath.path] {
			return CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .file, lastModifiedDate: lastModifiedDate, size: data.count)
		} else {
			throw CloudProviderError.itemNotFound
		}
	}

	private func deleteItem(at cloudPath: CloudPath) {
		state.withLock { $0.deleted.append(cloudPath.path) }
		mutationHook?()
	}

	private func moveItem(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) {
		state.withLock { $0.moved[sourceCloudPath.path] = targetCloudPath.path }
		mutationHook?()
	}
}

/// A transfer of `CloudProviderMock` that reports all of its bytes and then stays in flight until the test resumes it.
final class SuspendedTransfer: Sendable {
	let suspended = TestSignal("transfer suspended")
	private let outcomes: AsyncStream<Result<Void, Error>>
	private let continuation: AsyncStream<Result<Void, Error>>.Continuation

	init() {
		(self.outcomes, self.continuation) = AsyncStream.makeStream()
	}

	@Sendable
	func run(_ cloudPath: CloudPath, _ progress: Progress?) async throws {
		progress?.completedUnitCount = progress?.totalUnitCount ?? 0
		suspended.fulfill()
		for await outcome in outcomes {
			try outcome.get()
			break
		}
	}

	func resume(with outcome: Result<Void, Error> = .success(())) {
		continuation.yield(outcome)
	}
}

/// Waits for the value of the operation, which runs in a task that gets cancelled as soon as the provider made a remote change.
func valueCancelledAfterFirstRemoteChange<Value: Sendable>(of provider: CloudProviderMock, _ operation: @escaping @Sendable () async throws -> Value, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Value {
	let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
	let task = Task {
		for await _ in started {
			break
		}
		return try await operation()
	}
	provider.mutationHook = { task.cancel() }
	startedContinuation.yield()
	let result = try await cancellingValue(of: task, sourceLocation: sourceLocation)
	#expect(task.isCancelled, "No remote change cancelled the task", sourceLocation: sourceLocation)
	return result
}
