//
//  DownloadOperationTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DownloadOperationTests: XCTestCase {
	let itemMetadata = CloudItemMetadata(name: "file", cloudPath: CloudPath("/file"), itemType: .unknown, lastModifiedDate: Date(timeIntervalSince1970: 0), size: nil)
	var tmpDirURL: URL!
	var destinationURL: URL!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		destinationURL = tmpDirURL.appendingPathComponent("destination", isDirectory: false)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testDownload() async throws {
		let stagedFile = OSAllocatedUnfairLock<URL?>(initialState: nil)
		let downloadedMetadata = try await DownloadOperation.download(to: destinationURL, transfer: { stagedURL in
			XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
			try "hello world".write(to: stagedURL, atomically: true, encoding: .utf8)
			stagedFile.withLock { $0 = stagedURL }
			return self.itemMetadata
		})
		XCTAssertEqual("file", downloadedMetadata.name)
		XCTAssertEqual(CloudPath("/file"), downloadedMetadata.cloudPath)
		XCTAssertEqual(.file, downloadedMetadata.itemType)
		XCTAssertEqual(Date(timeIntervalSince1970: 0), downloadedMetadata.lastModifiedDate)
		XCTAssertEqual(11, downloadedMetadata.size)
		XCTAssertEqual("hello world", try String(contentsOf: destinationURL, encoding: .utf8))
		try assertDeleted(stagedFile.withLock { $0 })
	}

	func testDownloadWithTransferFailingAfterWriting() async throws {
		let stagedFile = OSAllocatedUnfairLock<URL?>(initialState: nil)
		await XCTAssertThrowsErrorAsync(try await DownloadOperation.download(to: destinationURL, transfer: { stagedURL in
			try "hello world".write(to: stagedURL, atomically: true, encoding: .utf8)
			stagedFile.withLock { $0 = stagedURL }
			throw CloudProviderError.itemNotFound
		})) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
		try assertDeleted(stagedFile.withLock { $0 })
	}

	func testDownloadWithCancellationBeforePublication() async throws {
		let destinationURL: URL = destinationURL
		let itemMetadata = itemMetadata
		let stagedFile = OSAllocatedUnfairLock<URL?>(initialState: nil)
		let download = Task {
			try await DownloadOperation.download(to: destinationURL, transfer: { stagedURL in
				try "hello world".write(to: stagedURL, atomically: true, encoding: .utf8)
				stagedFile.withLock { $0 = stagedURL }
				withUnsafeCurrentTask { $0?.cancel() }
				return itemMetadata
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
		try assertDeleted(stagedFile.withLock { $0 })
	}

	func testDownloadWithDestinationCreatedDuringTransfer() async throws {
		let stagedFile = OSAllocatedUnfairLock<URL?>(initialState: nil)
		await XCTAssertThrowsErrorAsync(try await DownloadOperation.download(to: destinationURL, transfer: { stagedURL in
			try "hello world".write(to: stagedURL, atomically: true, encoding: .utf8)
			stagedFile.withLock { $0 = stagedURL }
			try "other".write(to: self.destinationURL, atomically: true, encoding: .utf8)
			return self.itemMetadata
		})) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
		XCTAssertEqual("other", try String(contentsOf: destinationURL, encoding: .utf8))
		try assertDeleted(stagedFile.withLock { $0 })
	}

	// MARK: - Internal

	private func assertDeleted(_ stagedFile: URL?, file: StaticString = #filePath, line: UInt = #line) throws {
		let stagedFile = try XCTUnwrap(stagedFile, file: file, line: line)
		XCTAssertFalse(FileManager.default.fileExists(atPath: stagedFile.path), file: file, line: line)
	}
}
