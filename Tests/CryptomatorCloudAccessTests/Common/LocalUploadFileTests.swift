//
//  LocalUploadFileTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 17.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class LocalUploadFileTests {
		let tmpDirURL: URL

		init() throws {
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func regularFileKeepsURL() throws {
			let fileURL = try makeTargetFile()

			let file = try LocalUploadFile(fileURL)

			#expect(file.url == fileURL)
			#expect(file.size == 10)
		}

		@Test
		func symbolicLinkResolvesToTarget() throws {
			let linkURL = tmpDirURL.appendingPathComponent("link.bin")
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: makeTargetFile())

			let file = try LocalUploadFile(linkURL)

			try expectTarget(file)
		}

		@Test
		func chainOfSymbolicLinksResolvesToTarget() throws {
			let firstLinkURL = tmpDirURL.appendingPathComponent("first-link.bin")
			let secondLinkURL = tmpDirURL.appendingPathComponent("second-link.bin")
			try FileManager.default.createSymbolicLink(at: firstLinkURL, withDestinationURL: makeTargetFile())
			try FileManager.default.createSymbolicLink(at: secondLinkURL, withDestinationURL: firstLinkURL)

			let file = try LocalUploadFile(secondLinkURL)

			try expectTarget(file)
		}

		@Test
		func missingFileThrowsItemNotFound() {
			#expect(throws: CloudProviderError.itemNotFound) { try LocalUploadFile(self.tmpDirURL.appendingPathComponent("missing.bin")) }
		}

		@Test
		func danglingSymbolicLinkThrowsItemNotFound() throws {
			let linkURL = tmpDirURL.appendingPathComponent("link.bin")
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: tmpDirURL.appendingPathComponent("missing.bin"))

			#expect(throws: CloudProviderError.itemNotFound) { try LocalUploadFile(linkURL) }
		}

		@Test
		func folderThrowsItemTypeMismatch() {
			#expect(throws: CloudProviderError.itemTypeMismatch) { try LocalUploadFile(self.tmpDirURL) }
		}

		@Test
		func symbolicLinkToFolderThrowsItemTypeMismatch() throws {
			let linkURL = tmpDirURL.appendingPathComponent("link")
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: tmpDirURL)

			#expect(throws: CloudProviderError.itemTypeMismatch) { try LocalUploadFile(linkURL) }
		}

		@Test
		func fileInUnreadableFolderThrowsFileReadNoPermission() throws {
			let fileURL = try makeTargetFile()
			try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tmpDirURL.path)
			defer {
				try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpDirURL.path)
			}

			let error = try #require(throws: CocoaError.self) { try LocalUploadFile(fileURL) }

			#expect(error.code == .fileReadNoPermission)
			#expect((error.userInfo[NSUnderlyingErrorKey] as? POSIXError)?.code == .EACCES)
		}

		private func makeTargetFile() throws -> URL {
			let fileURL = tmpDirURL.appendingPathComponent("target.bin")
			try Data("0123456789".utf8).write(to: fileURL)
			return fileURL
		}

		private func expectTarget(_ file: LocalUploadFile) throws {
			#expect(file.url.lastPathComponent == "target.bin")
			#expect(try file.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
			#expect(file.size == 10)
		}
	}
}
