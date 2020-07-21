//
//  LocalFileSystemTests.swift
//  CloudAccessTests
//
//  Created by Tobias Hagemann on 20.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
@testable import CloudAccess

class LocalFileSystemTests: XCTestCase {
	var tmpDirURL: URL!
	var provider: LocalFileSystemProvider!

	override func setUpWithError() throws {
		tmpDirURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		provider = LocalFileSystemProvider()
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata")
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
		provider.fetchItemMetadata(at: fileURL).then { metadata in
			XCTAssertEqual("file", metadata.name)
			XCTAssertEqual(fileURL.path, metadata.remoteURL.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertNotNil(metadata.lastModifiedDate)
			XCTAssertEqual(11, metadata.size)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemMetadataWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata with itemNotFound error")
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		provider.fetchItemMetadata(at: fileURL).then { _ in
			XCTFail("Fetching metdata of a non-existing item should fail")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemMetadataWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata with itemTypeMismatch error")
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: true)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		provider.fetchItemMetadata(at: fileURL).then { _ in
			XCTFail("Fetching metadata of a file that is actually a folder should fail")
		}.catch { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemList() throws {
		let expectation = XCTestExpectation(description: "fetchItemList")
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		provider.fetchItemList(forFolderAt: tmpDirURL, withPageToken: nil).then { itemList in
			XCTAssertEqual(2, itemList.items.count)
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "dir" }))
			XCTAssertTrue(itemList.items.contains(where: { $0.name == "file" }))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "fetchItemList with itemNotFound error")
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		provider.fetchItemList(forFolderAt: dirURL, withPageToken: nil).then { _ in
			XCTFail("Fetching item list for a non-existing folder should fail")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testFetchItemListWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "fetchItemList with itemTypeMismatch error")
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		FileManager.default.createFile(atPath: dirURL.path, contents: nil, attributes: nil)
		provider.fetchItemList(forFolderAt: dirURL, withPageToken: nil).then { _ in
			XCTFail("Fetching item list for a folder that is actually a file should fail")
		}.catch { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFile() throws {
		let expectation = XCTestExpectation(description: "downloadFile")
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		provider.downloadFile(from: fileURL, to: localURL).then {
			let expectedData = try Data(contentsOf: fileURL)
			let actualData = try Data(contentsOf: localURL)
			XCTAssertEqual(expectedData, actualData)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "downloadFile with itemNotFound error")
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		provider.downloadFile(from: fileURL, to: localURL).then {
			XCTFail("Downloading non-existing file should fail")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFileWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "downloadFile with itemAlreadyExists error")
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		provider.downloadFile(from: fileURL, to: localURL).then {
			XCTFail("Downloading file to an existing resource should fail")
		}.catch { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDownloadFileWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "downloadFile with itemTypeMismatch error")
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false, attributes: nil)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		provider.downloadFile(from: fileURL, to: localURL).then {
			XCTFail("Downloading file that is actually a folder should fail")
		}.catch { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFile() throws {
		let expectation = XCTestExpectation(description: "uploadFile")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		provider.uploadFile(from: localURL, to: fileURL, replaceExisting: false).then { metadata in
			XCTAssertEqual("file", metadata.name)
			XCTAssertEqual(fileURL.path, metadata.remoteURL.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertNotNil(metadata.lastModifiedDate)
			XCTAssertEqual(11, metadata.size)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithReplaceExisting() throws {
		let expectation = XCTestExpectation(description: "uploadFile with replaceExisting")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "foo bar".write(to: fileURL, atomically: true, encoding: .utf8)
		provider.uploadFile(from: localURL, to: fileURL, replaceExisting: true).then { metadata in
			XCTAssertEqual("file", metadata.name)
			XCTAssertEqual(fileURL.path, metadata.remoteURL.path)
			XCTAssertEqual(.file, metadata.itemType)
			XCTAssertNotNil(metadata.lastModifiedDate)
			XCTAssertEqual(11, metadata.size)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with itemNotFound error")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		provider.uploadFile(from: localURL, to: fileURL, replaceExisting: false).then { _ in
			XCTFail("Uploading non-existing file should fail")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with itemAlreadyExists error")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		provider.uploadFile(from: localURL, to: fileURL, replaceExisting: false).then { _ in
			XCTFail("Uploading file to an existing item should fail")
		}.catch { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with itemTypeMismatch error")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		provider.uploadFile(from: localURL, to: fileURL, replaceExisting: false).then { _ in
			XCTFail("Uploading file that is actually a folder should fail")
		}.catch { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithReplaceExistingAndTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with replaceExisting and itemTypeMismatch error")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("dir", isDirectory: false)
		try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false, attributes: nil)
		provider.uploadFile(from: localURL, to: fileURL, replaceExisting: true).then { _ in
			XCTFail("Uploading and replacing file that is actually a folder should fail")
		}.catch { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testUploadFileWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "uploadFile with parentFolderDoesNotExist error")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("dir/file", isDirectory: false)
		provider.uploadFile(from: localURL, to: fileURL, replaceExisting: false).then { _ in
			XCTFail("Uploading file into a non-existing parent folder should fail")
		}.catch { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolder() throws {
		let expectation = XCTestExpectation(description: "createFolder")
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		provider.createFolder(at: dirURL).then {
			var isDirectory: ObjCBool = false
			XCTAssertTrue(FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDirectory))
			XCTAssertTrue(isDirectory.boolValue)
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolderWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "createFolder with itemAlreadyExists error")
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		provider.createFolder(at: dirURL).then {
			XCTFail("Creating folder at an existing item should fail")
		}.catch { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testCreateFolderWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "createFolder with parentFolderDoesNotExist error")
		let dirURL = tmpDirURL.appendingPathComponent("dir/dir", isDirectory: true)
		provider.createFolder(at: dirURL).then {
			XCTFail("Creating folder at a non-existing parent folder should fail")
		}.catch { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFolder() throws {
		let expectation = XCTestExpectation(description: "deleteItem on folder")
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("dir/file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		provider.deleteItem(at: dirURL).then {
			XCTAssertFalse(FileManager.default.fileExists(atPath: dirURL.path))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteFile() throws {
		let expectation = XCTestExpectation(description: "deleteItem on file")
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		provider.deleteItem(at: fileURL).then {
			XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteItemWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "deleteItem with itemNotFound error")
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		provider.deleteItem(at: fileURL).then {
			XCTFail("Deleting non-existing item should fail")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testDeleteItemWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "deleteItem with itemTypeMismatch error")
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		provider.deleteItem(at: tmpDirURL.appendingPathComponent("file", isDirectory: true)).then {
			XCTFail("Deleting folder that is actually a file should fail")
		}.catch { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItem() throws {
		let expectation = XCTestExpectation(description: "moveItem")
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: false)
		provider.moveItem(from: sourceURL, to: destinationURL).then {
			XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
			XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItemWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "moveItem with itemNotFound error")
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: false)
		provider.moveItem(from: sourceURL, to: destinationURL).then {
			XCTFail("Moving non-existing item should fail")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItemWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "moveItem with itemAlreadyExists error")
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: false)
		FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)
		provider.moveItem(from: sourceURL, to: destinationURL).then {
			XCTFail("Moving item to an existing item should fail")
		}.catch { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItemWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "moveItem with itemTypeMismatch error")
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: true)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: true)
		provider.moveItem(from: sourceURL, to: destinationURL).then {
			XCTFail("Moving folder that is actually a file should fail")
		}.catch { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}

	func testMoveItemWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "moveItem with parentFolderDoesNotExist error")
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		let destinationURL = tmpDirURL.appendingPathComponent("bar/baz", isDirectory: false)
		provider.moveItem(from: sourceURL, to: destinationURL).then {
			XCTFail("Moving item to a non-existing parent folder should fail")
		}.catch { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}
}
