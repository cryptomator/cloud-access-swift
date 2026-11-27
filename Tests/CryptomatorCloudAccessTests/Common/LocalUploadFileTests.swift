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
			self.tmpDirURL = try makeTemporaryDirectory()
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func regularFileKeepsURL() throws {
			let fileURL = try makeLocalFile(in: tmpDirURL, named: "target.bin", content: "0123456789")

			let file = try LocalUploadFile(fileURL)

			#expect(file.url == fileURL)
			#expect(file.size == 10)
		}

		@Test
		func symbolicLinkResolvesToTarget() throws {
			let linkURL = tmpDirURL.appending(component: "link.bin", directoryHint: .notDirectory)
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: makeLocalFile(in: tmpDirURL, named: "target.bin", content: "0123456789"))

			let file = try LocalUploadFile(linkURL)

			try expectTarget(file)
		}

		@Test
		func chainOfSymbolicLinksResolvesToTarget() throws {
			let firstLinkURL = tmpDirURL.appending(component: "first-link.bin", directoryHint: .notDirectory)
			let secondLinkURL = tmpDirURL.appending(component: "second-link.bin", directoryHint: .notDirectory)
			try FileManager.default.createSymbolicLink(at: firstLinkURL, withDestinationURL: makeLocalFile(in: tmpDirURL, named: "target.bin", content: "0123456789"))
			try FileManager.default.createSymbolicLink(at: secondLinkURL, withDestinationURL: firstLinkURL)

			let file = try LocalUploadFile(secondLinkURL)

			try expectTarget(file)
		}

		@Test
		func missingFileThrowsItemNotFound() {
			#expect(throws: CloudProviderError.itemNotFound) { try LocalUploadFile(self.tmpDirURL.appending(component: "missing.bin", directoryHint: .notDirectory)) }
		}

		@Test
		func danglingSymbolicLinkThrowsItemNotFound() throws {
			let linkURL = tmpDirURL.appending(component: "link.bin", directoryHint: .notDirectory)
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: tmpDirURL.appending(component: "missing.bin", directoryHint: .notDirectory))

			#expect(throws: CloudProviderError.itemNotFound) { try LocalUploadFile(linkURL) }
		}

		@Test
		func folderThrowsItemTypeMismatch() {
			#expect(throws: CloudProviderError.itemTypeMismatch) { try LocalUploadFile(self.tmpDirURL) }
		}

		@Test
		func symbolicLinkToFolderThrowsItemTypeMismatch() throws {
			let linkURL = tmpDirURL.appending(component: "link", directoryHint: .notDirectory)
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: tmpDirURL)

			#expect(throws: CloudProviderError.itemTypeMismatch) { try LocalUploadFile(linkURL) }
		}

		@Test
		func fileInUnreadableFolderThrowsFileReadNoPermission() throws {
			let fileURL = try makeLocalFile(in: tmpDirURL, named: "target.bin", content: "0123456789")
			try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tmpDirURL.path)
			defer {
				try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpDirURL.path)
			}

			let error = try #require(throws: CocoaError.self) { try LocalUploadFile(fileURL) }

			#expect(error.code == .fileReadNoPermission)
			#expect((error.userInfo[NSUnderlyingErrorKey] as? POSIXError)?.code == .EACCES)
		}

		private func expectTarget(_ file: LocalUploadFile) throws {
			#expect(file.url.lastPathComponent == "target.bin")
			#expect(try file.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
			#expect(file.size == 10)
		}
	}
}
