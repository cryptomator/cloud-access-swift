//
//  CloudProvider+CreateIntermediateFolderTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 12.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import Foundation
import os
import XCTest

enum CloudProviderFolderMockError: Error {
	case notMocked
}

private final class CloudProviderFolderMock: CloudProvider {
	let existingFolders: [CloudPath]
	private let lockedCreatedFolders = OSAllocatedUnfairLock(initialState: [CloudPath]())
	var createdFolders: [CloudPath] {
		lockedCreatedFolders.withLock { $0 }
	}

	init(existingFolders: [CloudPath] = []) {
		self.existingFolders = existingFolders
	}

	@concurrent
	func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata {
		throw CloudProviderFolderMockError.notMocked
	}

	@concurrent
	func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		throw CloudProviderFolderMockError.notMocked
	}

	@concurrent
	func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata {
		throw CloudProviderFolderMockError.notMocked
	}

	@concurrent
	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata {
		throw CloudProviderFolderMockError.notMocked
	}

	@concurrent
	func createFolder(at cloudPath: CloudPath) async throws {
		try lockedCreatedFolders.withLock { createdFolders in
			guard !createdFolders.contains(cloudPath), !existingFolders.contains(cloudPath) else {
				throw CloudProviderError.itemAlreadyExists
			}
			createdFolders.append(cloudPath)
		}
	}

	@concurrent
	func deleteFile(at cloudPath: CloudPath) async throws {
		throw CloudProviderFolderMockError.notMocked
	}

	@concurrent
	func deleteFolder(at cloudPath: CloudPath) async throws {
		throw CloudProviderFolderMockError.notMocked
	}

	@concurrent
	func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		throw CloudProviderFolderMockError.notMocked
	}

	@concurrent
	func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws {
		throw CloudProviderFolderMockError.notMocked
	}
}

class CloudProvider_CreateIntermediateFolderTests: XCTestCase {
	func testDoesNotCreateAnyFolderForRootPath() async throws {
		let provider = CloudProviderFolderMock()
		try await provider.createFolderWithIntermediates(for: CloudPath("/"))
		guard provider.createdFolders.isEmpty else {
			XCTFail("Provider created at least one folder")
			return
		}
	}

	func testCreateFolderWithIntermediates() async throws {
		let provider = CloudProviderFolderMock()
		let path = CloudPath("/Foo/Bar")
		try await provider.createFolderWithIntermediates(for: path)
		guard provider.createdFolders.count == 2 else {
			XCTFail("Provider created not exactly two folders")
			return
		}
		XCTAssert(provider.createdFolders.contains(CloudPath("/Foo")))
		XCTAssert(provider.createdFolders.contains(CloudPath("/Foo/Bar")))
	}

	func testCreateFolderWithIntermediatesIfAFolderAlreadyExists() async throws {
		let provider = CloudProviderFolderMock(existingFolders: [CloudPath("/Foo")])
		let path = CloudPath("/Foo/Bar")
		try await provider.createFolderWithIntermediates(for: path)
		guard provider.createdFolders.count == 1 else {
			XCTFail("Provider created not exactly two folders")
			return
		}
		XCTAssert(provider.createdFolders.contains(CloudPath("/Foo/Bar")))
	}
}
