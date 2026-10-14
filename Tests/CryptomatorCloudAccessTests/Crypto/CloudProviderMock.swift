//
//  CloudProviderMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// `@unchecked Sendable`: `folders`, `files`, `maxPageSize` and `lastModifiedDate` are immutable, everything else is protected by `state`. The class is subclassed by the vault format mocks.
public class CloudProviderMock: CloudProvider, @unchecked Sendable {
	private struct State {
		var calls: [String] = []
		var createdFolders: [String] = []
		var createdFiles: [String: Data] = [:]
		var deleted: [String] = []
		var moved: [String: String] = [:]
		var transferHook: (@Sendable (CloudPath, Progress?) async throws -> Void)?
		var mutationHook: (@Sendable () -> Void)?
		var metadataHook: (@Sendable (CloudPath) -> Void)?
	}

	let folders: Set<String>
	let files: [String: Data]
	let maxPageSize: Int
	let lastModifiedDate = Date(timeIntervalSinceReferenceDate: 0)
	private let state = OSAllocatedUnfairLock(initialState: State())

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

	/// Runs before the metadata of an item is fetched.
	var metadataHook: (@Sendable (CloudPath) -> Void)? {
		get { state.withLock { $0.metadataHook } }
		set { state.withLock { $0.metadataHook = newValue } }
	}

	init(folders: Set<String>, files: [String: Data], maxPageSize: Int = .max) {
		self.folders = folders
		self.files = files
		self.maxPageSize = maxPageSize
	}

	@concurrent
	public func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		try Task.checkCancellation()
		record("fetchItemMetadata")
		metadataHook?(cloudPath)
		return try getItemMetadata(at: cloudPath)
	}

	@concurrent
	public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		try Task.checkCancellation()
		record("fetchItemList")
		let parentPath = cloudPath.path
		let parentPathLvl = parentPath.components(separatedBy: "/").count
		let childDirs = folders.filter { $0.hasPrefix(parentPath) && $0.components(separatedBy: "/").count == parentPathLvl + 1 }
		let childFiles = files.keys.filter { $0.hasPrefix(parentPath) && $0.components(separatedBy: "/").count == parentPathLvl + 1 }
		let children = (childDirs + childFiles).sorted()
		let pageStart = pageToken.flatMap(Int.init) ?? 0
		let page = children.dropFirst(pageStart).prefix(maxPageSize)
		let nextPageStart = pageStart + page.count
		return try CloudItemList(items: page.map { try getItemMetadata(at: CloudPath($0)) }, nextPageToken: nextPageStart < children.count ? String(nextPageStart) : nil)
	}

	@concurrent
	public func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		record("downloadFile")
		guard let data = files[cloudPath.path] else {
			throw CloudProviderError.itemNotFound
		}
		let phases = Progress.phases(of: progress, 999)
		try await transferHook?(cloudPath, phases[0])
		try data.write(to: localURL, options: .withoutOverwriting)
		phases.completeTransfer()
		return CloudItemMetadata(name: cloudPath.lastPathComponent, cloudPath: cloudPath, itemType: .file, lastModifiedDate: lastModifiedDate, size: data.count)
	}

	@concurrent
	public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		precondition(localURL.isFileURL)
		try Task.checkCancellation()
		record("uploadFile")
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
		try Task.checkCancellation()
		record("createFolder")
		state.withLock { $0.createdFolders.append(cloudPath.path) }
		mutationHook?()
	}

	@concurrent
	public func deleteFile(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		record("deleteFile")
		deleteItem(at: cloudPath)
	}

	@concurrent
	public func deleteFolder(at cloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		record("deleteFolder")
		guard !deleted.contains(cloudPath.path), folders.contains(cloudPath.path) || createdFolders.contains(cloudPath.path) else {
			throw CloudProviderError.itemNotFound
		}
		deleteItem(at: cloudPath)
	}

	@concurrent
	public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		record("moveFile")
		moveItem(from: sourceCloudPath, to: targetCloudPath)
	}

	@concurrent
	public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try Task.checkCancellation()
		record("moveFolder")
		moveItem(from: sourceCloudPath, to: targetCloudPath)
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
	let suspended = XCTestExpectation(description: "transfer suspended")
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

extension XCTestCase {
	/// Waits for the value of the operation, which runs in a task that gets cancelled as soon as the provider made a remote change.
	func valueCancelledAfterFirstRemoteChange<Value: Sendable>(of provider: CloudProviderMock, _ operation: @escaping @Sendable () async throws -> Value, file: StaticString = #filePath, line: UInt = #line) async throws -> Value {
		let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
		let task = Task {
			for await _ in started {
				break
			}
			return try await operation()
		}
		provider.mutationHook = { task.cancel() }
		startedContinuation.yield()
		let result = try await value(of: task, file: file, line: line)
		XCTAssertTrue(task.isCancelled, "No remote change cancelled the task", file: file, line: line)
		return result
	}
}
