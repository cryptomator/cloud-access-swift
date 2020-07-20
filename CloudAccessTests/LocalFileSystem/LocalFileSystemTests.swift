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

	func testMoveItemWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "moveItem with itemAlreadyExists error")
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: false)
		FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)
		provider.moveItem(from: sourceURL, to: destinationURL).then {
			XCTFail("Moving item to an existing resource should fail")
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
}
