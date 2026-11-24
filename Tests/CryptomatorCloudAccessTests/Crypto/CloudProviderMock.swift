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

/**
 A cloud provider that holds its items in memory and keeps the `CloudProvider` contract: its reads reflect its own writes, and it refuses with the documented error what the contract refuses.

 Its paths are the tests' relative fixture paths. Every ancestor of a seeded item is a folder, and a path of one segment lies at a top level that always exists. It doesn't model the refusals of the root and of unresolvable paths, because every fixture path is relative and the vault decorators refuse such cleartext paths before any request.

 `@unchecked Sendable`: `maxPageSize`, `reversesPages` and `lastModifiedDate` are immutable, everything else is protected by `state`.
 */
public final class CloudProviderMock: CloudProvider, @unchecked Sendable {
	/// The alias markers move with the item and vanish with it, also when an upload replaces it.
	private struct Item {
		var data: Data?
		var isAlias = false
		var isAliasedDownload = false

		var isFolder: Bool {
			return data == nil
		}
	}

	/// What a delete or move changes before it throws an injected error. The error decides it, so that a test can't pair an error with a change that contradicts it.
	private enum Effect {
		case none
		case copy
		case full

		init(of failure: Error?) {
			switch failure as? CloudProviderError {
			case .deletionIncomplete:
				self = .none
			case .moveCompletedWithSourceRemaining:
				self = .copy
			default:
				self = .full
			}
		}
	}

	private struct State {
		var items: [String: Item]
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
		var mutationFailure: (@Sendable (String, CloudPath) -> Error?)?

		func item(at path: String) throws -> Item {
			guard let item = items[path] else {
				throw CloudProviderError.itemNotFound
			}
			return item
		}

		/// Sorted by path, because a page token is an offset into them.
		func children(ofFolderAt path: String) throws -> [(path: String, item: Item)] {
			guard try item(at: path).isFolder else {
				throw CloudProviderError.itemTypeMismatch
			}
			return items.filter { CloudProviderMock.parentPath(of: $0.key) == path }.map { (path: $0.key, item: $0.value) }.sorted { $0.path < $1.path }
		}

		/// A path of one segment lies at the top level, which always exists.
		func requireParent(of path: String) throws {
			guard let parentPath = CloudProviderMock.parentPath(of: path) else {
				return
			}
			guard items[parentPath]?.isFolder == true else {
				throw CloudProviderError.parentFolderDoesNotExist
			}
		}

		func checkUploadTarget(_ path: String, replaceExisting: Bool) throws {
			if let existingItem = items[path], existingItem.isFolder || !replaceExisting {
				throw CloudProviderError.itemAlreadyExists
			}
			try requireParent(of: path)
		}

		/// The item at the path and the items below it. Descendants match by the bytes of the path and a slash, because a slash forms one `Character` with a combining mark after it.
		func subtree(at path: String) -> [String: Item] {
			let descendantPrefix = "\(path)/"
			return items.filter { $0.key == path || $0.key.hasUTF8Prefix(descendantPrefix) }
		}

		mutating func removeSubtree(at path: String) {
			for subpath in subtree(at: path).keys {
				items[subpath] = nil
			}
		}

		mutating func copySubtree(from sourcePath: String, to targetPath: String) {
			for (subpath, item) in subtree(at: sourcePath) {
				items[targetPath + String(Substring(subpath.utf8.dropFirst(sourcePath.utf8.count)))] = item
			}
		}
	}

	let maxPageSize: Int
	let reversesPages: Bool
	let lastModifiedDate = Date(timeIntervalSinceReferenceDate: 0)
	private let state: OSAllocatedUnfairLock<State>

	/// The folders that the provider holds now.
	var folders: Set<String> {
		state.withLock { Set($0.items.filter(\.value.isFolder).keys) }
	}

	/// The files that the provider holds now.
	var files: [String: Data] {
		state.withLock { $0.items.compactMapValues(\.data) }
	}

	/// The names of the methods called so far, also of a call that the provider refused or that then threw `CancellationError` because its task was cancelled.
	var calls: [String] {
		state.withLock { $0.calls }
	}

	/// The folders that a creation added, in order.
	var createdFolders: [String] {
		state.withLock { $0.createdFolders }
	}

	/// The files that an upload wrote, with the data of the last upload to each path.
	var createdFiles: [String: Data] {
		state.withLock { $0.createdFiles }
	}

	/// The paths of the deletes that the provider accepted, in order, also of one whose injected failure removed nothing. A recursive delete records only its path.
	var deleted: [String] {
		state.withLock { $0.deleted }
	}

	/// The targets of the moves that the provider accepted, by source, also of one whose injected failure moved nothing.
	var moved: [String: String] {
		state.withLock { $0.moved }
	}

	/// Runs while a download or an upload of the given cloud path is in flight, with the progress of its bytes.
	var transferHook: (@Sendable (CloudPath, Progress?) async throws -> Void)? {
		get { state.withLock { $0.transferHook } }
		set { state.withLock { $0.transferHook = newValue } }
	}

	/// Runs after each upload, folder creation, deletion and move that changed the provider's items.
	var mutationHook: (@Sendable () -> Void)? {
		get { state.withLock { $0.mutationHook } }
		set { state.withLock { $0.mutationHook = newValue } }
	}

	/// Runs before the metadata of an item is fetched, which fails with the error that the hook throws.
	var metadataHook: (@Sendable (CloudPath) throws -> Void)? {
		get { state.withLock { $0.metadataHook } }
		set { state.withLock { $0.metadataHook = newValue } }
	}

	/// Runs after `metadataHook` and returns the metadata of an item instead of the provider's, which it falls back to for `nil`. An error that it throws fails the call.
	var metadataOverride: (@Sendable (CloudPath) throws -> CloudItemMetadata?)? {
		get { state.withLock { $0.metadataOverride } }
		set { state.withLock { $0.metadataOverride = newValue } }
	}

	/// Runs before a file move checks anything. The move fails with the error that the hook throws.
	var moveHook: (@Sendable () throws -> Void)? {
		get { state.withLock { $0.moveHook } }
		set { state.withLock { $0.moveHook = newValue } }
	}

	/// Runs before a page of the given folder is listed, with its page token, which fails with the error that the hook throws.
	var listingHook: (@Sendable (CloudPath, String?) throws -> Void)? {
		get { state.withLock { $0.listingHook } }
		set { state.withLock { $0.listingHook = newValue } }
	}

	/// Returns the error that a deletion or a move throws once it passed the provider's checks, or `nil`. It gets the name of the call and its cloud path (a move's source). `deletionIncomplete` removes nothing, `moveCompletedWithSourceRemaining` copies the source to the target, and any other error applies the whole change before it is thrown.
	var mutationFailure: (@Sendable (String, CloudPath) -> Error?)? {
		get { state.withLock { $0.mutationFailure } }
		set { state.withLock { $0.mutationFailure = newValue } }
	}

	/// Returns a `mutationFailure` that fails the call of the given name with the error at the given cloud paths, or at every path if `paths` is empty.
	static func failing(_ call: String, with error: Error, at paths: Set<String> = []) -> @Sendable (String, CloudPath) -> Error? {
		return { mutation, cloudPath in
			mutation == call && (paths.isEmpty || paths.contains(cloudPath.path)) ? error : nil
		}
	}

	/// Returns a `metadataOverride` that answers the reads of the given cloud path with the given item types in order, repeating the last one. A `nil` type answers with `CloudProviderError.itemNotFound`. Other cloud paths fall back to the provider's items.
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

	/**
	 Holds the given folders and files, and every ancestor of them as a folder.

	 A listing marks the items at `aliases` as aliases, as a provider marks a shortcut. A download of a file at `aliasedDownloads` reports an alias, as Google Drive and Microsoft Graph do when the path, or the folder that holds it, resolves to one. Metadata reads mark neither.

	 `reversesPages` lists the items of each page in reverse order.
	 */
	init(folders: Set<String>, files: [String: Data], maxPageSize: Int = .max, aliases: Set<String> = [], aliasedDownloads: Set<String> = [], reversesPages: Bool = false) {
		var items = [String: Item]()
		for path in folders {
			items[path] = Item()
		}
		for (path, data) in files {
			precondition(items[path] == nil, "\(path) is seeded as a file and as a folder")
			items[path] = Item(data: data)
		}
		for path in Array(items.keys) {
			for ancestor in Self.ancestors(of: path) {
				precondition(items[ancestor]?.isFolder ?? true, "\(ancestor) is seeded as a file but holds \(path)")
				if items[ancestor] == nil {
					items[ancestor] = Item()
				}
			}
		}
		for path in aliases {
			precondition(items[path] != nil, "\(path) is marked as an alias but not seeded")
			items[path]?.isAlias = true
		}
		for path in aliasedDownloads {
			precondition(items[path]?.isFolder == false, "\(path) is marked as an aliased download but not seeded as a file")
			items[path]?.isAliasedDownload = true
		}
		self.maxPageSize = maxPageSize
		self.reversesPages = reversesPages
		self.state = OSAllocatedUnfairLock(initialState: State(items: items))
	}

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		record("fetchItemMetadata")
		try Task.checkCancellation()
		try metadataHook?(cloudPath)
		if let metadata = try metadataOverride?(cloudPath) {
			return metadata
		}
		let item = try state.withLock { try $0.item(at: cloudPath.path) }
		return metadata(of: item, at: cloudPath)
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		record("fetchItemList")
		try Task.checkCancellation()
		try listingHook?(cloudPath, pageToken)
		let children = try state.withLock { try $0.children(ofFolderAt: cloudPath.path) }
		let pageStart = pageToken.flatMap(Int.init) ?? 0
		let page = children.dropFirst(pageStart).prefix(maxPageSize)
		let nextPageStart = pageStart + page.count
		let items = page.map { child in
			metadata(of: child.item, at: CloudPath(child.path), isAlias: child.item.isAlias)
		}
		return CloudItemList(items: reversesPages ? items.reversed() : items, nextPageToken: nextPageStart < children.count ? String(nextPageStart) : nil)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		record("downloadFile")
		try Task.checkCancellation()
		let item = try state.withLock { try $0.item(at: cloudPath.path) }
		guard let data = item.data else {
			throw CloudProviderError.itemTypeMismatch
		}
		let phases = Progress.phases(of: progress, 999)
		try await transferHook?(cloudPath, phases[0])
		try data.write(to: localURL, options: .withoutOverwriting)
		phases.completeTransfer()
		return metadata(of: item, at: cloudPath, isAlias: item.isAliasedDownload)
	}

	/// Checks the target before the transfer, and again when the upload takes effect after it.
	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		record("uploadFile")
		try Task.checkCancellation()
		try state.withLock { try $0.checkUploadTarget(cloudPath.path, replaceExisting: replaceExisting) }
		let data = try Data(contentsOf: localURL)
		let phases = Progress.phases(of: progress, 999)
		try await transferHook?(cloudPath, phases[0])
		let item = Item(data: data)
		try state.withLock { state in
			try state.checkUploadTarget(cloudPath.path, replaceExisting: replaceExisting)
			state.items[cloudPath.path] = item
			state.createdFiles[cloudPath.path] = data
		}
		mutationHook?()
		phases.completeTransfer()
		return metadata(of: item, at: cloudPath)
	}

	@concurrent
	public func createFolder(at cloudPath: CloudPath) async throws {
		record("createFolder")
		try Task.checkCancellation()
		try state.withLock { state in
			guard state.items[cloudPath.path] == nil else {
				throw CloudProviderError.itemAlreadyExists
			}
			try state.requireParent(of: cloudPath.path)
			state.items[cloudPath.path] = Item()
			state.createdFolders.append(cloudPath.path)
		}
		mutationHook?()
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		record("deleteFile")
		try Task.checkCancellation()
		try deleteItem("deleteFile", at: cloudPath, isFolder: false)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		record("deleteFolder")
		try Task.checkCancellation()
		try deleteItem("deleteFolder", at: cloudPath, isFolder: true)
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		record("moveFile")
		try Task.checkCancellation()
		try moveHook?()
		try moveItem("moveFile", from: sourceCloudPath, to: targetCloudPath, isFolder: false)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		record("moveFolder")
		try Task.checkCancellation()
		try moveItem("moveFolder", from: sourceCloudPath, to: targetCloudPath, isFolder: true)
	}

	private func record(_ call: String) {
		state.withLock { $0.calls.append(call) }
	}

	private func metadata(of item: Item, at cloudPath: CloudPath, isAlias: Bool = false) -> CloudItemMetadata {
		if let data = item.data {
			return CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .file, lastModifiedDate: lastModifiedDate, size: data.count, isAlias: isAlias)
		} else {
			return CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .folder, lastModifiedDate: lastModifiedDate, size: 0, isAlias: isAlias)
		}
	}

	private func deleteItem(_ call: String, at cloudPath: CloudPath, isFolder: Bool) throws {
		let failure = mutationFailure?(call, cloudPath)
		let effect = Effect(of: failure)
		try state.withLock { state in
			guard try state.item(at: cloudPath.path).isFolder == isFolder else {
				throw CloudProviderError.itemTypeMismatch
			}
			state.deleted.append(cloudPath.path)
			if effect == .full {
				state.removeSubtree(at: cloudPath.path)
			}
		}
		if effect == .full {
			mutationHook?()
		}
		if let failure {
			throw failure
		}
	}

	private func moveItem(_ call: String, from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath, isFolder: Bool) throws {
		let failure = mutationFailure?(call, sourceCloudPath)
		let effect = Effect(of: failure)
		try state.withLock { state in
			guard try state.item(at: sourceCloudPath.path).isFolder == isFolder else {
				throw CloudProviderError.itemTypeMismatch
			}
			try state.requireParent(of: targetCloudPath.path)
			guard state.items[targetCloudPath.path] == nil else {
				throw CloudProviderError.itemAlreadyExists
			}
			state.moved[sourceCloudPath.path] = targetCloudPath.path
			if effect != .none {
				state.copySubtree(from: sourceCloudPath.path, to: targetCloudPath.path)
			}
			if effect == .full {
				state.removeSubtree(at: sourceCloudPath.path)
			}
		}
		if effect != .none {
			mutationHook?()
		}
		if let failure {
			throw failure
		}
	}

	/// The proper ancestors of the path, found by the bytes of its slashes, because a slash forms one `Character` with a combining mark after it.
	private static func ancestors(of path: String) -> [String] {
		let utf8 = path.utf8
		return utf8.indices.filter { $0 != utf8.startIndex && utf8[$0] == UInt8(ascii: "/") }.map { String(Substring(utf8[..<$0])) }
	}

	/// The path of the parent, or `nil` for a path of one segment.
	private static func parentPath(of path: String) -> String? {
		let utf8 = path.utf8
		return utf8.lastIndex(of: UInt8(ascii: "/")).map { String(Substring(utf8[..<$0])) }
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
