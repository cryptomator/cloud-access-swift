//
//  DownloadOperationTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class DownloadOperationTests {
		let itemMetadata = CloudItemMetadata(name: "file", cloudPath: CloudPath("/file"), itemType: .unknown, lastModifiedDate: Date(timeIntervalSince1970: 0), size: nil)
		let tmpDirURL: URL
		let destinationURL: URL

		init() throws {
			let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			self.tmpDirURL = tmpDirURL
			self.destinationURL = tmpDirURL.appendingPathComponent("destination", isDirectory: false)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func testDownload() async throws {
			let stagedFile = OSAllocatedUnfairLock<URL?>(initialState: nil)
			let downloadedMetadata = try await DownloadOperation.download(to: destinationURL, transfer: { stagedURL in
				#expect(!FileManager.default.fileExists(atPath: stagedURL.path))
				#expect(try ProcessTemporaryDirectory.shared.directoryURL().path == stagedURL.deletingLastPathComponent().path)
				try "hello world".write(to: stagedURL, atomically: true, encoding: .utf8)
				stagedFile.withLock { $0 = stagedURL }
				return self.itemMetadata
			})
			#expect(downloadedMetadata.name == "file")
			#expect(CloudPath("/file") == downloadedMetadata.cloudPath)
			#expect(downloadedMetadata.itemType == .file)
			#expect(Date(timeIntervalSince1970: 0) == downloadedMetadata.lastModifiedDate)
			#expect(downloadedMetadata.size == 11)
			#expect(try String(contentsOf: destinationURL, encoding: .utf8) == "hello world")
			try assertDeleted(stagedFile.withLock { $0 })
		}

		@Test
		func downloadWithTransferFailingAfterWriting() async throws {
			let stagedFile = OSAllocatedUnfairLock<URL?>(initialState: nil)
			await #expect(throws: CloudProviderError.itemNotFound) {
				try await DownloadOperation.download(to: destinationURL, transfer: { stagedURL in
					try "hello world".write(to: stagedURL, atomically: true, encoding: .utf8)
					stagedFile.withLock { $0 = stagedURL }
					throw CloudProviderError.itemNotFound
				})
			}
			#expect(!FileManager.default.fileExists(atPath: destinationURL.path))
			try assertDeleted(stagedFile.withLock { $0 })
		}

		@Test
		func downloadWithCancellationBeforePublication() async throws {
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
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }
			#expect(!FileManager.default.fileExists(atPath: destinationURL.path))
			try assertDeleted(stagedFile.withLock { $0 })
		}

		@Test
		func downloadWithDestinationCreatedDuringTransfer() async throws {
			let stagedFile = OSAllocatedUnfairLock<URL?>(initialState: nil)
			await #expect(throws: CloudProviderError.itemAlreadyExists) {
				try await DownloadOperation.download(to: destinationURL, transfer: { stagedURL in
					try "hello world".write(to: stagedURL, atomically: true, encoding: .utf8)
					stagedFile.withLock { $0 = stagedURL }
					try "other".write(to: self.destinationURL, atomically: true, encoding: .utf8)
					return self.itemMetadata
				})
			}
			#expect(try String(contentsOf: destinationURL, encoding: .utf8) == "other")
			try assertDeleted(stagedFile.withLock { $0 })
		}

		// MARK: - Internal

		private func assertDeleted(_ stagedFile: URL?, sourceLocation: SourceLocation = #_sourceLocation) throws {
			let stagedFile = try #require(stagedFile, sourceLocation: sourceLocation)
			#expect(!FileManager.default.fileExists(atPath: stagedFile.path), sourceLocation: sourceLocation)
		}
	}
}
