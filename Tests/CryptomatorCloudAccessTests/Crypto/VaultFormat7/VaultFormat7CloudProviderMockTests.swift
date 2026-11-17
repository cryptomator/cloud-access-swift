//
//  VaultFormat7CloudProviderMockTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class VaultFormat7CloudProviderMockTests {
		let tmpDirURL: URL

		init() throws {
			let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			self.tmpDirURL = tmpDirURL
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func vaultRootContainsFiles() async throws {
			let provider = VaultFormat7CloudProviderMock()
			let cloudItemList = try await provider.fetchItemList(forFolderAt: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"), withPageToken: nil)
			#expect(cloudItemList.items.count == 6)
			#expect(cloudItemList.items.contains(where: { $0.name == "dir1.c9r" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "file1.c9r" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "file2.c9r" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s" }))
		}

		@Test
		func dir1FileContainsDirId() async throws {
			let provider = VaultFormat7CloudProviderMock()
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let metadata = try await provider.fetchItemMetadata(at: CloudPath("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r"))
			#expect(metadata.itemType == .file)
			_ = try await provider.downloadFile(from: metadata.cloudPath, to: localURL)
			let downloadedContents = try Data(contentsOf: localURL)
			#expect(Data("dir1-id".utf8) == downloadedContents)
		}
	}
}
