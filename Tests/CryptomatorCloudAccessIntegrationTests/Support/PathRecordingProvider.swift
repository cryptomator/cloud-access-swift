//
//  PathRecordingProvider.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 10.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccess
import Foundation
import os

/// Forwards every call to its delegate and records the cloud path of each call that succeeded: the target of a move, and the path of any other call.
final class PathRecordingProvider: CloudProvider {
	enum Operation: Sendable {
		case fetchItemMetadata
		case fetchItemList
		case downloadFile
		case uploadFile
		case createFolder
		case deleteFile
		case deleteFolder
		case moveFile
		case moveFolder

		var createsItem: Bool {
			switch self {
			case .uploadFile, .createFolder, .moveFile, .moveFolder:
				return true
			case .fetchItemMetadata, .fetchItemList, .downloadFile, .deleteFile, .deleteFolder:
				return false
			}
		}
	}

	private struct State {
		var paths = [Operation: [CloudPath]]()
		var createdPaths = [CloudPath]()
	}

	// swiftlint:disable:next weak_delegate
	private let delegate: CloudProvider
	private let state = OSAllocatedUnfairLock(initialState: State())

	init(delegate: CloudProvider) {
		self.delegate = delegate
	}

	func paths(of operation: Operation) -> [CloudPath] {
		return state.withLock { $0.paths[operation] ?? [] }
	}

	/// The paths that items were uploaded, created or moved to since the last call of this method.
	func takeCreatedPaths() -> [CloudPath] {
		return state.withLock { state in
			defer { state.createdPaths = [] }
			return state.createdPaths
		}
	}

	private func record(_ operation: Operation, _ cloudPath: CloudPath) {
		state.withLock { state in
			state.paths[operation, default: []].append(cloudPath)
			if operation.createsItem {
				state.createdPaths.append(cloudPath)
			}
		}
	}

	// MARK: - CloudProvider API

	@concurrent
	func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		let metadata = try await delegate.fetchItemMetadata(at: cloudPath)
		record(.fetchItemMetadata, cloudPath)
		return metadata
	}

	@concurrent
	func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		let itemList = try await delegate.fetchItemList(forFolderAt: cloudPath, withPageToken: pageToken)
		record(.fetchItemList, cloudPath)
		return itemList
	}

	@concurrent
	func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		let metadata = try await delegate.downloadFile(from: cloudPath, to: localURL, progress: progress, onTaskCreation: onTaskCreation)
		record(.downloadFile, cloudPath)
		return metadata
	}

	@concurrent
	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		let metadata = try await delegate.uploadFile(from: localURL, to: cloudPath, replaceExisting: replaceExisting, progress: progress, onTaskCreation: onTaskCreation)
		record(.uploadFile, cloudPath)
		return metadata
	}

	@concurrent
	func createFolder(at cloudPath: CloudPath) async throws {
		try await delegate.createFolder(at: cloudPath)
		record(.createFolder, cloudPath)
	}

	@concurrent
	func deleteFile(at cloudPath: CloudPath) async throws {
		try await delegate.deleteFile(at: cloudPath)
		record(.deleteFile, cloudPath)
	}

	@concurrent
	func deleteFolder(at cloudPath: CloudPath) async throws {
		try await delegate.deleteFolder(at: cloudPath)
		record(.deleteFolder, cloudPath)
	}

	@concurrent
	func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try await delegate.moveFile(from: sourceCloudPath, to: targetCloudPath)
		record(.moveFile, targetCloudPath)
	}

	@concurrent
	func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		try await delegate.moveFolder(from: sourceCloudPath, to: targetCloudPath)
		record(.moveFolder, targetCloudPath)
	}
}
