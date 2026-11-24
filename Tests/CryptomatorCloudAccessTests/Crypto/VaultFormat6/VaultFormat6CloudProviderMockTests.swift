//
//  VaultFormat6CloudProviderMockTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class VaultFormat6CloudProviderMockTests {
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
			let provider = CloudProviderMock.vaultFormat6()
			let cloudItemList = try await provider.fetchItemList(forFolderAt: CloudPath(VaultTestFormat.rootDirectory), withPageToken: nil)
			#expect(cloudItemList.items.count == 6)
			#expect(cloudItemList.items.contains(where: { $0.name == "0dir1" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "file1" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "file2" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng" }))
			#expect(cloudItemList.items.contains(where: { $0.name == "CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng" }))
		}

		@Test
		func dir1FileContainsDirId() async throws {
			let provider = CloudProviderMock.vaultFormat6()
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let metadata = try await provider.fetchItemMetadata(at: CloudPath("\(VaultTestFormat.rootDirectory)/0dir1"))
			#expect(metadata.itemType == .file)
			_ = try await provider.downloadFile(from: metadata.cloudPath, to: localURL)
			let downloadedContents = try Data(contentsOf: localURL)
			#expect(Data("dir1-id".utf8) == downloadedContents)
		}
	}
}
