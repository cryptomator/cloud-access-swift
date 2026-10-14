//
//  CloudAccessIntegrationTestWithAuthentication.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 16.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import XCTest

class CloudAccessIntegrationTestWithAuthentication: CloudAccessIntegrationTest {
	func deauthenticate() async throws {
		fatalError("Not implemented")
	}

	func testFetchItemMetadataWithUnauthorizedError() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		try await deauthenticate()
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: cloudPath), "fetchItemMetadata fulfilled without authentication") { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testFetchItemListWithUnauthorizedError() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder")
		try await deauthenticate()
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil), "fetchItemList fulfilled without authentication") { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testDownloadFileWithUnauthorizedError() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try await deauthenticate()
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: cloudPath, to: localURL), "downloadFile fulfilled without authentication") { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testUploadFileWithUnauthorizedError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let testContent = CloudAccessIntegrationTest.testContentForFilesInTestFolder
		try testContent.write(to: localURL, atomically: true, encoding: .utf8)
		let cloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/test 5.txt")
		try await deauthenticate()
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false), "uploadFile fulfilled without authentication") { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testCreateFolderWithUnauthorizedError() async throws {
		let cloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolder")
		try await deauthenticate()
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: cloudPath), "createFolder fulfilled without authentication") { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testDeleteFileWithUnauthorizedError() async throws {
		let cloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolder")
		try await deauthenticate()
		await XCTAssertThrowsErrorAsync(try await provider.deleteFile(at: cloudPath), "deleteFile fulfilled without authentication") { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testDeleteFolderWithUnauthorizedError() async throws {
		let cloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolder")
		try await deauthenticate()
		await XCTAssertThrowsErrorAsync(try await provider.deleteFolder(at: cloudPath), "deleteFolder fulfilled without authentication") { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testMoveFileWithUnauthorizedError() async throws {
		let sourceCloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolder")
		let targetCloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolderAA")
		try await deauthenticate()
		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: sourceCloudPath, to: targetCloudPath), "moveFile fulfilled without authentication") { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testMoveFolderWithUnauthorizedError() async throws {
		let sourceCloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolder")
		let targetCloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolderAA")
		try await deauthenticate()
		await XCTAssertThrowsErrorAsync(try await provider.moveFolder(from: sourceCloudPath, to: targetCloudPath), "moveFolder fulfilled without authentication") { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testOperationsInCancelledTaskThrowCancellationError() async throws {
		try await assertOperationsThrowCancellationErrorInCancelledTask()
	}
}
