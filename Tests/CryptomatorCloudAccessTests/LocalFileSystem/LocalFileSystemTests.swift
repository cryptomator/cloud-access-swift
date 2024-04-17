//
//  LocalFileSystemTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import Foundation
import XCTest

class LocalFileSystemTests: XCTestCase {
	var tmpDirURL: URL!
	var provider: LocalFileSystemProvider!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		provider = try LocalFileSystemProvider(rootURL: tmpDirURL)
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testFetchItemMetadata() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/file")).async()
		XCTAssertEqual("file", metadata.name)
		XCTAssertEqual("/file", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertNotNil(metadata.lastModifiedDate)
		XCTAssertEqual(11, metadata.size)
	}

	func testFetchItemMetadataWithNotFoundError() async {
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/file")).async()) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testFetchItemList() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).async()
		XCTAssertEqual(2, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "dir" && $0.cloudPath.path == "/dir" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "file" && $0.cloudPath.path == "/file" }))
	}

	func testFetchItemListWithNotFoundError() async {
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/dir"), withPageToken: nil).async()) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testFetchItemListWithTypeMismatchError() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		FileManager.default.createFile(atPath: dirURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: CloudPath("/dir"), withPageToken: nil).async()) { error in
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testFetchItemListFiltersHiddenItems() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		let hiddenDirURL = tmpDirURL.appendingPathComponent(".hiddenDir", isDirectory: true)
		try FileManager.default.createDirectory(at: hiddenDirURL, withIntermediateDirectories: false, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		let hiddenFileURL = tmpDirURL.appendingPathComponent(".hiddenFile", isDirectory: false)
		FileManager.default.createFile(atPath: hiddenFileURL.path, contents: nil, attributes: nil)
		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil).async()
		XCTAssertEqual(2, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "dir" && $0.cloudPath.path == "/dir" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "file" && $0.cloudPath.path == "/file" }))
	}

	func testDownloadFile() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try await provider.downloadFile(from: CloudPath("/file"), to: localURL).async()
		let expectedData = try Data(contentsOf: fileURL)
		let actualData = try Data(contentsOf: localURL)
		XCTAssertEqual(expectedData, actualData)
	}

	func testDownloadFileWithNotFoundError() async {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file"), to: localURL).async()) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithAlreadyExistsError() async {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file"), to: localURL).async()) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithTypeMismatchError() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false, attributes: nil)
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file"), to: localURL).async()) { error in
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testUploadFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false).async()
		XCTAssertEqual("file", metadata.name)
		XCTAssertEqual("/file", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertNotNil(metadata.lastModifiedDate)
		XCTAssertEqual(11, metadata.size)
	}

	func testUploadFileWithReplaceExistingOnMissingRemoteFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: true).async()
		XCTAssertEqual("file", metadata.name)
		XCTAssertEqual("/file", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertNotNil(metadata.lastModifiedDate)
		XCTAssertEqual(11, metadata.size)
	}

	func testUploadFileWithReplaceExistingOnExistingRemoteFile() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "hello world".write(to: localURL, atomically: true, encoding: .utf8)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		try "foo bar".write(to: fileURL, atomically: true, encoding: .utf8)
		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: true).async()
		XCTAssertEqual("file", metadata.name)
		XCTAssertEqual("/file", metadata.cloudPath.path)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertNotNil(metadata.lastModifiedDate)
		XCTAssertEqual(11, metadata.size)
	}

	func testUploadFileWithNotFoundError() async {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false).async()) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testUploadFileWithAlreadyExistsError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false).async()) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testUploadFileWithTypeMismatchError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file"), replaceExisting: false).async()) { error in
			XCTAssertEqual(CloudProviderError.itemTypeMismatch, error as? CloudProviderError)
		}
	}

	func testUploadFileWithReplaceExistingAndAlreadyExistsError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("dir", isDirectory: false)
		try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/dir"), replaceExisting: true).async()) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testUploadFileWithParentFolderDoesNotExistError() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		FileManager.default.createFile(atPath: localURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/dir/file"), replaceExisting: false).async()) { error in
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testCreateFolder() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try await provider.createFolder(at: CloudPath("/dir")).async()
		var isDirectory: ObjCBool = false
		XCTAssertTrue(FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDirectory))
		XCTAssertTrue(isDirectory.boolValue)
	}

	func testCreateFolderWithAlreadyExistsError() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: CloudPath("/dir")).async()) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testCreateFolderWithParentFolderDoesNotExistError() async {
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: CloudPath("/dir/dir")).async()) { error in
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testDeleteFile() async throws {
		let fileURL = tmpDirURL.appendingPathComponent("file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		try await provider.deleteFile(at: CloudPath("/file")).async()
		XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
	}

	func testDeleteFileWithNotFoundError() async {
		await XCTAssertThrowsErrorAsync(try await provider.deleteFile(at: CloudPath("/file")).async()) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDeleteFolder() async throws {
		let dirURL = tmpDirURL.appendingPathComponent("dir", isDirectory: true)
		try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false, attributes: nil)
		let fileURL = tmpDirURL.appendingPathComponent("dir/file", isDirectory: false)
		FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
		try await provider.deleteFolder(at: CloudPath("/dir")).async()
		XCTAssertFalse(FileManager.default.fileExists(atPath: dirURL.path))
	}

	func testMoveFile() async throws {
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: false)
		try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar")).async()
		XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
	}

	func testMoveFileWithNotFoundError() async {
		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar")).async()) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testMoveFileWithAlreadyExistsError() async {
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		let destinationURL = tmpDirURL.appendingPathComponent("bar", isDirectory: false)
		FileManager.default.createFile(atPath: destinationURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar")).async()) { error in
			XCTAssertEqual(CloudProviderError.itemAlreadyExists, error as? CloudProviderError)
		}
	}

	func testMoveFileWithParentFolderDoesNotExistError() async {
		let sourceURL = tmpDirURL.appendingPathComponent("foo", isDirectory: false)
		FileManager.default.createFile(atPath: sourceURL.path, contents: nil, attributes: nil)
		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: CloudPath("/foo"), to: CloudPath("/bar/baz")).async()) { error in
			XCTAssertEqual(CloudProviderError.parentFolderDoesNotExist, error as? CloudProviderError)
		}
	}

	func testGetItemName() {
		let iCloudPlaceholderFileURL = tmpDirURL.appendingPathComponent(".test.txt.icloud")
		XCTAssertEqual("test.txt", provider.getItemName(forItemAt: iCloudPlaceholderFileURL))

		let normalFileURL = tmpDirURL.appendingPathComponent("test.txt")
		XCTAssertEqual("test.txt", provider.getItemName(forItemAt: normalFileURL))

		let normalFolderURL = tmpDirURL.appendingPathComponent("Foo")
		XCTAssertEqual("Foo", provider.getItemName(forItemAt: normalFolderURL))

		let otherHiddenFileURL = tmpDirURL.appendingPathComponent(".test.txt")
		XCTAssertEqual(".test.txt", provider.getItemName(forItemAt: otherHiddenFileURL))

		let otherHiddenFolderURL = tmpDirURL.appendingPathComponent(".Foo")
		XCTAssertEqual(".Foo", provider.getItemName(forItemAt: otherHiddenFolderURL))
	}
}
