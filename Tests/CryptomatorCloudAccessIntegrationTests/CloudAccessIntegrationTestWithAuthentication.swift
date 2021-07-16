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
@testable import Promises

class CloudAccessIntegrationTestWithAuthentication: CloudAccessIntegrationTest {
	func deauthenticate() -> Promise<Void> {
		fatalError("Not implemented")
	}

	func testFetchItemMetadataWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "unauthorized fetchItemMetadata")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		deauthenticate().then {
			self.provider.fetchItemMetadata(at: cloudPath)
		}.then { _ in
			XCTFail("fetchItemMetadata fulfilled without authentication")
		}.catch { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemListWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "unauthorized fetchItemList")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder")
		deauthenticate().then {
			self.provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil)
		}.then { _ in
			XCTFail("fetchItemList fulfilled without authentication")
		}.catch { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testDownloadFileWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "unauthorized downloadFile")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		deauthenticate().then {
			self.provider.downloadFile(from: cloudPath, to: localURL)
		}.then { _ in
			XCTFail("downloadFile fulfilled without authentication")
		}.catch { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testUploadFileWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "unauthorized uploadFile")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let testContent = CloudAccessIntegrationTest.testContentForFilesInTestFolder
		try testContent.write(to: localURL, atomically: true, encoding: .utf8)
		let cloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/test 5.txt")
		deauthenticate().then {
			self.provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false)
		}.then { _ in
			XCTFail("uploadFile fulfilled without authentication")
		}.catch { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testCreateFolderWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "unauthorized createFolder")
		let cloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolder")
		deauthenticate().then {
			self.provider.createFolder(at: cloudPath)
		}.then { _ in
			XCTFail("createFolder fulfilled without authentication")
		}.catch { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testDeleteFileWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "unauthorized deleteFile")
		let cloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolder")
		deauthenticate().then {
			self.provider.deleteFile(at: cloudPath)
		}.then { _ in
			XCTFail("deleteFile fulfilled without authentication")
		}.catch { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testDeleteFolderWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "unauthorized deleteFolder")
		let cloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolder")
		deauthenticate().then {
			self.provider.deleteFolder(at: cloudPath)
		}.then { _ in
			XCTFail("deleteFolder fulfilled without authentication")
		}.catch { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testMoveFileWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "unauthorized moveFile")
		let sourceCloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolder")
		let targetCloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolderAA")
		deauthenticate().then {
			self.provider.moveFile(from: sourceCloudPath, to: targetCloudPath)
		}.then { _ in
			XCTFail("moveFile fulfilled without authentication")
		}.catch { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testMoveFolderWithUnauthorizedError() throws {
		let expectation = XCTestExpectation(description: "unauthorized moveFolder")
		let sourceCloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolder")
		let targetCloudPath = CloudAccessIntegrationTest.integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/unauthorizedFolderAA")
		deauthenticate().then {
			self.provider.moveFolder(from: sourceCloudPath, to: targetCloudPath)
		}.then { _ in
			XCTFail("moveFolder fulfilled without authentication")
		}.catch { error in
			guard case CloudProviderError.unauthorized = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}
}
