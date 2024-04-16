//
//  CloudAccessIntegrationTest.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 29.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import XCTest
@testable import Promises

class CloudAccessIntegrationTest: XCTestCase {
	static let testContentForFilesInRoot = "testContent"
	static let testContentForFilesInTestFolder = "File inside Folder Content"

	static var classSetUpError: Error?
	static var setUpProvider: CloudProvider!
	static var integrationTestParentCloudPath: CloudPath!
	static var integrationTestRootCloudPath: CloudPath {
		integrationTestParentCloudPath.appendingPathComponent("IntegrationTest")
	}

	override class var defaultTestSuite: XCTestSuite {
		// Return empty `XCTestSuite` so that no tests from this "abstract" `XCTestCase` is run.
		// Make sure to override this in subclasses so that the implemented test case can run.
		return XCTestSuite(name: "InterfaceTests Excluded")
	}

	let maxPageSizeForLimitedCloudProvider = 3
	var tmpDirURL: URL!
	var provider: CloudProvider!
	var expectedRootFolderItems: [CloudItemMetadata] {
		let cloudPath = type(of: self).integrationTestRootCloudPath
		return [CloudItemMetadata(name: "test 0.txt", cloudPath: cloudPath.appendingPathComponent("test 0.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
		        CloudItemMetadata(name: "test 1.txt", cloudPath: cloudPath.appendingPathComponent("test 1.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
		        CloudItemMetadata(name: "test 2.txt", cloudPath: cloudPath.appendingPathComponent("test 2.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
		        CloudItemMetadata(name: "test 3.txt", cloudPath: cloudPath.appendingPathComponent("test 3.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
		        CloudItemMetadata(name: "test 4.txt", cloudPath: cloudPath.appendingPathComponent("test 4.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
		        CloudItemMetadata(name: "testFolder", cloudPath: cloudPath.appendingPathComponent("testFolder"), itemType: .folder, lastModifiedDate: nil, size: nil)]
	}

	override class func setUp() {
		precondition(setUpProvider != nil)
		precondition(integrationTestParentCloudPath != nil)
		let setUpPromise = setUpForIntegrationTest(at: setUpProvider, integrationTestRootCloudPath: integrationTestRootCloudPath)
		// Use `waitForPromises()` as expectations are not available here. Therefore, we can't catch the error from the promise above. And we need to check for an error later.
		guard waitForPromises(timeout: 120.0) else {
			classSetUpError = IntegrationTestError.oneTimeSetUpTimeout
			return
		}
		if let error = setUpPromise.error {
			classSetUpError = error
		}
	}

	override class func tearDown() {
		_ = setUpProvider.deleteFolder(at: integrationTestRootCloudPath).then {
			setUpProvider = nil
		}
		_ = waitForPromises(timeout: 60.0)
	}

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		if let error = type(of: self).classSetUpError {
			throw error
		}
	}

	override func tearDownWithError() throws {
		provider = nil
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	/**
	 Creates a CloudProvider with a `maxPageSize` of `maxPageSizeForLimitedCloudProvider` to test pagination.

	 This method must be overridden by each subclass.
	 */
	func createLimitedCloudProvider() throws -> CloudProvider {
		fatalError("Provided only abstract implementation of createLimitedCloudProvider()")
	}

	/**
	 Initial setup for the integration tests.

	 Creates the following integration test structure at the cloud provider:

	 ```
	 └─ integrationTestRootCloudPath
	    ├─ testFolder
	    │  ├─ EmptySubfolder
	    │  ├─ FolderForDeleteItems
	    │  │  ├─ FileForItemTypeMismatch
	    │  │  ├─ FileToDelete
	    │  │  ├─ FolderForItemTypeMismatch
	    │  │  └─ FolderToDelete
	    │  ├─ FolderForMoveItems
	    │  │  ├─ FileForItemAlreadyExists
	    │  │  ├─ FileForItemTypeMismatch
	    │  │  ├─ FileForParentFolderDoesNotExist
	    │  │  ├─ FileToMove
	    │  │  ├─ FileToRename
	    │  │  ├─ FolderForItemAlreadyExists
	    │  │  ├─ FolderForItemTypeMismatch
	    │  │  ├─ FolderForParentFolderDoesNotExist
	    │  │  ├─ FolderToMove
	    │  │  ├─ FolderToRename
	    │  │  └─ MoveItemsInThisFolder
	    │  ├─ test 0.txt
	    │  ├─ test 1.txt
	    │  ├─ test 2.txt
	    │  ├─ test 3.txt
	    │  └─ test 4.txt
	    ├─ test 0.txt
	    ├─ test 1.txt
	    ├─ test 2.txt
	    ├─ test 3.txt
	    └─ test 4.txt
	 ```
	 */
	private static func setUpForIntegrationTest(at provider: CloudProvider, integrationTestRootCloudPath: CloudPath) -> Promise<Void> {
		let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		do {
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			try createRootFolderContent(at: tmpDirURL) // locally create the full test directory (incl. all descendants)
		} catch {
			try? FileManager.default.removeItem(at: tmpDirURL)
			return Promise(error)
		}
		return deepCopyLocalContentToCloud(from: tmpDirURL, to: integrationTestRootCloudPath, with: provider).always {
			try? FileManager.default.removeItem(at: tmpDirURL)
		}
	}

	private static func createRootFolderContent(at url: URL) throws {
		for i in 0 ..< 5 {
			let testFileURL = url.appendingPathComponent("test \(i).txt", isDirectory: false)
			try testContentForFilesInRoot.write(to: testFileURL, atomically: true, encoding: .utf8)
		}

		let testFolderURL = url.appendingPathComponent("testFolder", isDirectory: true)
		try FileManager.default.createDirectory(at: testFolderURL, withIntermediateDirectories: false)
		try createTestFolderContent(at: testFolderURL)
	}

	private static func createTestFolderContent(at url: URL) throws {
		for i in 0 ..< 5 {
			let testFileURL = url.appendingPathComponent("test \(i).txt", isDirectory: false)
			try testContentForFilesInTestFolder.write(to: testFileURL, atomically: true, encoding: .utf8)
		}

		let emptySubfolderURL = url.appendingPathComponent("EmptySubfolder", isDirectory: true)
		try FileManager.default.createDirectory(at: emptySubfolderURL, withIntermediateDirectories: false)

		let folderForDeleteItemsURL = url.appendingPathComponent("FolderForDeleteItems", isDirectory: true)
		try FileManager.default.createDirectory(at: folderForDeleteItemsURL, withIntermediateDirectories: false)
		try createFolderForDeleteItemsContent(at: folderForDeleteItemsURL)

		let folderForMoveItemsURL = url.appendingPathComponent("FolderForMoveItems", isDirectory: true)
		try FileManager.default.createDirectory(at: folderForMoveItemsURL, withIntermediateDirectories: false)
		try createFolderForMoveItemsContent(at: folderForMoveItemsURL)
	}

	private static func createFolderForDeleteItemsContent(at url: URL) throws {
		let testContent = "AAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBABABABABABBABABABBABABABABABAB"
		let fileForItemTypeMismatchURL = url.appendingPathComponent("FileForItemTypeMismatch", isDirectory: false)
		try testContent.write(to: fileForItemTypeMismatchURL, atomically: true, encoding: .utf8)
		let fileToDeleteURL = url.appendingPathComponent("FileToDelete", isDirectory: false)
		try testContent.write(to: fileToDeleteURL, atomically: true, encoding: .utf8)

		let folderForItemTypeMismatchURL = url.appendingPathComponent("FolderForItemTypeMismatch", isDirectory: true)
		try FileManager.default.createDirectory(at: folderForItemTypeMismatchURL, withIntermediateDirectories: false)
		let folderToDeleteURL = url.appendingPathComponent("FolderToDelete", isDirectory: true)
		try FileManager.default.createDirectory(at: folderToDeleteURL, withIntermediateDirectories: false)
	}

	private static func createFolderForMoveItemsContent(at url: URL) throws {
		let testContent = "AAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBABABABABABBABABABBABABABABABAB"
		let fileForItemAlreadyExistsURL = url.appendingPathComponent("FileForItemAlreadyExists", isDirectory: false)
		try testContent.write(to: fileForItemAlreadyExistsURL, atomically: true, encoding: .utf8)
		let fileForItemTypeMismatchURL = url.appendingPathComponent("FileForItemTypeMismatch", isDirectory: false)
		try testContent.write(to: fileForItemTypeMismatchURL, atomically: true, encoding: .utf8)
		let fileForParentFolderDoesNotExistURL = url.appendingPathComponent("FileForParentFolderDoesNotExist", isDirectory: false)
		try testContent.write(to: fileForParentFolderDoesNotExistURL, atomically: true, encoding: .utf8)
		let fileToMoveURL = url.appendingPathComponent("FileToMove", isDirectory: false)
		try testContent.write(to: fileToMoveURL, atomically: true, encoding: .utf8)
		let fileToRenameURL = url.appendingPathComponent("FileToRename", isDirectory: false)
		try testContent.write(to: fileToRenameURL, atomically: true, encoding: .utf8)

		let folderForItemAlreadyExistsURL = url.appendingPathComponent("FolderForItemAlreadyExists", isDirectory: true)
		try FileManager.default.createDirectory(at: folderForItemAlreadyExistsURL, withIntermediateDirectories: false)
		let folderForItemTypeMismatchURL = url.appendingPathComponent("FolderForItemTypeMismatch", isDirectory: true)
		try FileManager.default.createDirectory(at: folderForItemTypeMismatchURL, withIntermediateDirectories: false)
		let folderForParentFolderDoesNotExistURL = url.appendingPathComponent("FolderForParentFolderDoesNotExist", isDirectory: true)
		try FileManager.default.createDirectory(at: folderForParentFolderDoesNotExistURL, withIntermediateDirectories: false)
		let folderToMoveURL = url.appendingPathComponent("FolderToMove", isDirectory: true)
		try FileManager.default.createDirectory(at: folderToMoveURL, withIntermediateDirectories: false)
		let folderToRenameURL = url.appendingPathComponent("FolderToRename", isDirectory: true)
		try FileManager.default.createDirectory(at: folderToRenameURL, withIntermediateDirectories: false)
		let moveItemsInThisFolderURL = url.appendingPathComponent("MoveItemsInThisFolder", isDirectory: true)
		try FileManager.default.createDirectory(at: moveItemsInThisFolderURL, withIntermediateDirectories: false)
	}

	private static func deepCopyLocalContentToCloud(from url: URL, to cloudPath: CloudPath, with provider: CloudProvider) -> Promise<Void> {
		return Promise<Void>(on: .global()) { fulfill, reject in
			do {
				try awaitPromise(provider.deleteFolderIfExisting(at: cloudPath))
				try awaitPromise(provider.createFolderWithIntermediates(for: cloudPath))
				guard let enumerator = FileManager.default.enumerator(atPath: url.path) else {
					reject(IntegrationTestError.missingDirectoryEnumerator)
					return
				}
				while let nextObject = enumerator.nextObject() as? String {
					let fileURL = url.appendingPathComponent(nextObject)
					var isDirectory: ObjCBool = false
					FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
					let cloudPath = integrationTestRootCloudPath.appendingPathComponent(nextObject)
					if isDirectory.boolValue {
						try awaitPromise(provider.createFolder(at: cloudPath))
					} else {
						_ = try awaitPromise(provider.uploadFile(from: fileURL, to: cloudPath, replaceExisting: false))
					}
				}
				fulfill(())
			} catch {
				reject(error)
			}
		}
	}

	// MARK: - fetchItemMetadata Tests

	func testFetchItemMetadataForFile() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata for file")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		provider.fetchItemMetadata(at: cloudPath).then { metadata in
			XCTAssertEqual("test 0.txt", metadata.name)
			XCTAssertEqual(cloudPath, metadata.cloudPath)
			XCTAssertEqual(CloudItemType.file, metadata.itemType)
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemMetadataForFolder() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata for folder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder")
		provider.fetchItemMetadata(at: cloudPath).then { metadata in
			XCTAssertEqual("testFolder", metadata.name)
			XCTAssertEqual(cloudPath, metadata.cloudPath)
			XCTAssertEqual(CloudItemType.folder, metadata.itemType)
			expectation.fulfill()
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemMetadataForFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata for nonexistent file")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("thisFileMustNotExist.pdf")
		provider.fetchItemMetadata(at: cloudPath).then { _ in
			XCTFail("Promise should not fulfill for nonexistent file")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail("Promise rejected but with the wrong error: \(error)")
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemMetadataForFolderWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata for nonexistent folder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("thisFolderMustNotExist")
		provider.fetchItemMetadata(at: cloudPath).then { _ in
			XCTFail("Promise should not fulfill for nonexistent folder")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail("Promise rejected but with the wrong error: \(error)")
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemMetadataForFileInSubfolder() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata for file in subfolder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/test 0.txt")
		provider.fetchItemMetadata(at: cloudPath).then { metadata in
			XCTAssertEqual("test 0.txt", metadata.name)
			XCTAssertEqual(cloudPath, metadata.cloudPath)
			XCTAssertEqual(CloudItemType.file, metadata.itemType)
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemMetadataForFolderInSubfolder() throws {
		let expectation = XCTestExpectation(description: "fetchItemMetadata for folder in subfolder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder")
		provider.fetchItemMetadata(at: cloudPath).then { metadata in
			XCTAssertEqual("EmptySubfolder", metadata.name)
			XCTAssertEqual(cloudPath, metadata.cloudPath)
			XCTAssertEqual(CloudItemType.folder, metadata.itemType)
			expectation.fulfill()
		}.catch { error in
			XCTFail(error.localizedDescription)
		}
		wait(for: [expectation], timeout: 60.0)
	}

	// MARK: - fetchItemList Tests

	func testFetchItemListForRootFolder() throws {
		let expectation = XCTestExpectation(description: "fetchItemList for root folder")
		let cloudPath = type(of: self).integrationTestRootCloudPath
		provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil).then { retrievedItemList in
			let retrievedSortedItems = retrievedItemList.items.sorted()
			XCTAssertNil(retrievedItemList.nextPageToken)
			XCTAssertEqual(self.expectedRootFolderItems, retrievedSortedItems)
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemListForSubfolder() throws {
		let expectation = XCTestExpectation(description: "fetchItemList for subfolder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder")
		let expectedItems = [
			CloudItemMetadata(name: "EmptySubfolder", cloudPath: cloudPath.appendingPathComponent("EmptySubfolder"), itemType: .folder, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "FolderForDeleteItems", cloudPath: cloudPath.appendingPathComponent("FolderForDeleteItems"), itemType: .folder, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "FolderForMoveItems", cloudPath: cloudPath.appendingPathComponent("FolderForMoveItems"), itemType: .folder, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "test 0.txt", cloudPath: cloudPath.appendingPathComponent("test 0.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "test 1.txt", cloudPath: cloudPath.appendingPathComponent("test 1.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "test 2.txt", cloudPath: cloudPath.appendingPathComponent("test 2.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "test 3.txt", cloudPath: cloudPath.appendingPathComponent("test 3.txt"), itemType: .file, lastModifiedDate: nil, size: nil),
			CloudItemMetadata(name: "test 4.txt", cloudPath: cloudPath.appendingPathComponent("test 4.txt"), itemType: .file, lastModifiedDate: nil, size: nil)
		]
		provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil).then { retrievedItemList in
			let retrievedSortedItems = retrievedItemList.items.sorted()
			XCTAssertNil(retrievedItemList.nextPageToken)
			XCTAssertEqual(expectedItems, retrievedSortedItems)
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemListForEmptyFolder() throws {
		let expectation = XCTestExpectation(description: "fetchItemList for empty folder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder")
		let expectedItems = [CloudItemMetadata]()
		provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil).then { retrievedItemList in
			let retrievedSortedItems = retrievedItemList.items.sorted()
			XCTAssertNil(retrievedItemList.nextPageToken)
			XCTAssertEqual(expectedItems, retrievedSortedItems)
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemListWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "fetchItemList for nonexistent folder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("thisFolderMustNotExist")
		provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil).then { _ in
			XCTFail("fetchItemList fulfilled for nonexistent folder")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail("Promise rejected but with the wrong error: \(error)")
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemListWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "fetchItemList for file")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil).then { _ in
			XCTFail("fetchItemList fulfilled for file")
		}.catch { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemListWithPageTokenInvalidError() throws {
		let expectation = XCTestExpectation(description: "fetchItemList with invalid page token")
		let cloudPath = type(of: self).integrationTestRootCloudPath
		provider.fetchItemList(forFolderAt: cloudPath, withPageToken: "invalidPageToken").then { _ in
			XCTFail("fetchItemList fulfilled with invalid page token")
		}.catch { error in
			guard case CloudProviderError.pageTokenInvalid = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testFetchItemListPagination() throws {
		let expectation = XCTestExpectation()
		let provider = try createLimitedCloudProvider()
		let cloudPath = type(of: self).integrationTestRootCloudPath
		var retrievedItems = [CloudItemMetadata]()
		provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil).then { itemList -> Promise<CloudItemList> in
			XCTAssertNotNil(itemList.nextPageToken)
			XCTAssertEqual(3, itemList.items.count)
			retrievedItems.append(contentsOf: itemList.items)
			return provider.fetchItemList(forFolderAt: cloudPath, withPageToken: itemList.nextPageToken)
		}.then { itemList in
			XCTAssertNil(itemList.nextPageToken)
			XCTAssertEqual(3, itemList.items.count)
			retrievedItems.append(contentsOf: itemList.items)
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
		let sortedRetrievedItems = retrievedItems.sorted()
		XCTAssertEqual(expectedRootFolderItems, sortedRetrievedItems)
	}

	// MARK: - downloadFile Tests

	func testDownloadFileFromRootFolder() throws {
		let expectation = XCTestExpectation(description: "downloadFile from root folder")
		let expectedFileContent = type(of: self).testContentForFilesInRoot
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			print("\(progress.localizedDescription ?? "") (\(progress.localizedAdditionalDescription ?? ""))")
		}
		progress.becomeCurrent(withPendingUnitCount: 1)
		provider.downloadFile(from: cloudPath, to: localURL).then {
			let actualFileContent = try String(contentsOf: localURL)
			XCTAssertEqual(expectedFileContent, actualFileContent)
			XCTAssertTrue(progress.completedUnitCount >= progress.totalUnitCount)
		}.catch { error in
			XCTFail("Promise failed with error: \(error)")
		}.always {
			progressObserver.invalidate()
			expectation.fulfill()
		}
		progress.resignCurrent()
		wait(for: [expectation], timeout: 60.0)
	}

	func testDownloadFileFromSubfolder() throws {
		let expectation = XCTestExpectation(description: "downloadFile from subfolder")
		let expectedFileContent = type(of: self).testContentForFilesInTestFolder
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/test 0.txt")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			print("\(progress.localizedDescription ?? "") (\(progress.localizedAdditionalDescription ?? ""))")
		}
		progress.becomeCurrent(withPendingUnitCount: 1)
		provider.downloadFile(from: cloudPath, to: localURL).then {
			let actualFileContent = try String(contentsOf: localURL)
			XCTAssertEqual(expectedFileContent, actualFileContent)
		}.catch { error in
			XCTFail("Promise failed with error: \(error)")
		}.always {
			progressObserver.invalidate()
			expectation.fulfill()
		}
		progress.resignCurrent()
		wait(for: [expectation], timeout: 60.0)
	}

	func testDownloadFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "downloadFile for nonexistent file")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("thisFileMustNotExist.txt")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		provider.downloadFile(from: cloudPath, to: localURL).then { _ in
			XCTFail("downloadFile fulfilled for nonexistent file")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testDownloadFileWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "downloadFile to already existing file")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "".write(to: localURL, atomically: true, encoding: .utf8)
		provider.downloadFile(from: cloudPath, to: localURL).then { _ in
			XCTFail("downloadFile fulfilled to already existing file")
		}.catch { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testDownloadFileFailWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "downloadFile for folder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		provider.downloadFile(from: cloudPath, to: localURL).then { _ in
			XCTFail("downloadFile fulfilled for folder")
		}.catch { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	// MARK: - uploadFile Tests

	func testUploadFileWithReplaceExisting() throws {
		let expectation = XCTestExpectation(description: "uploadFile with replace existing")
		let initialLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let initialTestContent = "Start content"
		try initialTestContent.write(to: initialLocalURL, atomically: true, encoding: .utf8)
		let overwrittenLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let overwrittenTestContent = "Overwritten content"
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/FileToOverwrite.txt")
		let progress = Progress(totalUnitCount: 1)
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			print("\(progress.localizedDescription ?? "") (\(progress.localizedAdditionalDescription ?? ""))")
		}
		progress.becomeCurrent(withPendingUnitCount: 1)
		provider.uploadFile(from: initialLocalURL, to: cloudPath, replaceExisting: false).then { cloudItemMetadata -> Promise<CloudItemMetadata> in
			XCTAssertTrue(progress.completedUnitCount >= progress.totalUnitCount)
			self.assertReceivedCorrectMetadataAfterUploading(file: initialLocalURL, to: cloudPath, metadata: cloudItemMetadata)
			try overwrittenTestContent.write(to: initialLocalURL, atomically: true, encoding: .utf8)
			return self.provider.uploadFile(from: initialLocalURL, to: cloudPath, replaceExisting: true)
		}.then { cloudItemMetadata -> Promise<Void> in
			self.assertReceivedCorrectMetadataAfterUploading(file: initialLocalURL, to: cloudPath, metadata: cloudItemMetadata)
			return self.provider.downloadFile(from: cloudPath, to: overwrittenLocalURL)
		}.then { _ in
			self.provider.deleteFile(at: cloudPath)
		}.then {
			let downloadedContent = try String(contentsOf: overwrittenLocalURL)
			XCTAssertEqual(overwrittenTestContent, downloadedContent)
		}.catch { error in
			XCTFail("Promise failed with error: \(error)")
		}.always {
			progressObserver.invalidate()
			expectation.fulfill()
		}
		progress.resignCurrent()
		wait(for: [expectation], timeout: 60.0)
	}

	func testUploadFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "uploadFile for nonexistent file")
		let localURL = tmpDirURL.appendingPathComponent("nonExistentFile.txt", isDirectory: false)
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/nonExistentFile.txt")
		provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false).then { _ in
			XCTFail("uploadFile fulfilled for nonexistent file")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testUploadFileWithAlreadyExistsErrorAndNotReplaceExisting() throws {
		let expectation = XCTestExpectation(description: "uploadFile to already existing file without replace existing")
		let localURL = tmpDirURL.appendingPathComponent("test 0.txt", isDirectory: false)
		let testContent = type(of: self).testContentForFilesInTestFolder
		try testContent.write(to: localURL, atomically: true, encoding: .utf8)
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/test 0.txt")
		provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false).then { _ in
			XCTFail("uploadFile fulfilled to already existing file without replace existing")
		}.catch { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testUploadFileWithAlreadyExistsErrorAndReplaceExisting() throws {
		let expectation = XCTestExpectation(description: "uploadFile to already existing folder with replace existing")
		let localURL = tmpDirURL.appendingPathComponent("overwriteFolder.txt", isDirectory: false)
		let testContent = type(of: self).testContentForFilesInTestFolder
		try testContent.write(to: localURL, atomically: true, encoding: .utf8)
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/overwriteFolder.txt")
		provider.createFolder(at: cloudPath).then { _ in
			return self.provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: true)
		}.then { _ in
			XCTFail("uploadFile fulfilled to already existing folder with replace existing")
		}.catch { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testUploadFileWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "uploadFile to nonexistent parent folder")
		let localURL = tmpDirURL.appendingPathComponent("test 0.txt", isDirectory: false)
		let testContent = type(of: self).testContentForFilesInTestFolder
		try testContent.write(to: localURL, atomically: true, encoding: .utf8)
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/thisFolderMustNotExist/test 0.txt")
		provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false).then { _ in
			XCTFail("uploadFile fulfilled to nonexistent parent folder")
		}.catch { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testUploadFileWithTypeMismatchError() throws {
		let expectation = XCTestExpectation(description: "uploadFile for folder")
		let localURL = tmpDirURL.appendingPathComponent("itemTypeMismatchFolder", isDirectory: false)
		try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false, attributes: nil)
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("itemTypeMismatchFolder")
		provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false).then { _ in
			XCTFail("uploadFile fulfilled for folder")
		}.catch { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	// MARK: - createFolder Tests

	func testCreateFolderForFolderWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "createFolder for already existing folder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder")
		provider.createFolder(at: cloudPath).then { _ in
			XCTFail("createFolder fulfilled for already existing folder")
		}.catch { error in
			if case CloudProviderError.itemAlreadyExists = error {
				expectation.fulfill()
			} else {
				XCTFail(error.localizedDescription)
			}
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testCreateFolderForFileWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "createFolder for already existing file")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		provider.createFolder(at: cloudPath).then { _ in
			XCTFail("createFolder fulfilled for already existing file")
		}.catch { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testCreateFolderWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "createFolder to nonexistent parent folder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("thisFolderMustNotExist-AAA").appendingPathComponent("folderToCreate")
		provider.createFolder(at: cloudPath).then { _ in
			XCTFail("createFolder fulfilled to nonexistent parent folder")
		}.catch { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	// MARK: - deleteFile Tests

	func testDeleteFile() throws {
		let expectation = XCTestExpectation(description: "deleteFile can delete existing file")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForDeleteItems/FileToDelete")
		provider.deleteFile(at: cloudPath).then {
			self.provider.repeatedlyCheckForItemExistence(at: cloudPath, expectToExist: false)
		}.then { fileExists in
			guard !fileExists else {
				XCTFail("File still exists in the cloud")
				return
			}
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testDeleteFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "deleteFile for nonexistent file")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForDeleteItems/thisFileMustNotExist")
		provider.deleteFile(at: cloudPath).then {
			XCTFail("deleteFile fulfilled for nonexistent file")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	// MARK: - deleteFolder Tests

	func testDeleteFolderCanDeleteExistingFolder() throws {
		let expectation = XCTestExpectation(description: "deleteFolder can delete existing folder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForDeleteItems/FolderToDelete")
		provider.deleteFolder(at: cloudPath).then {
			self.provider.repeatedlyCheckForItemExistence(at: cloudPath, expectToExist: false)
		}.then { folderExists in
			guard !folderExists else {
				XCTFail("Folder still exists in the cloud")
				return
			}
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testDeleteFolderWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "deleteFolder for nonexistent folder")
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForDeleteItems/thisFolderMustNotExist")
		provider.deleteFolder(at: cloudPath).then {
			XCTFail("deleteFolder fulfilled for nonexistent folder")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	// MARK: - moveFile Tests

	func testMoveFileAsRename() throws {
		let expectation = XCTestExpectation(description: "moveFile can rename file")
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FileToRename")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/RenamedFile")
		provider.moveFile(from: sourceCloudPath, to: targetCloudPath).then {
			all(
				self.provider.repeatedlyCheckForItemExistence(at: sourceCloudPath, expectToExist: false),
				self.provider.repeatedlyCheckForItemExistence(at: targetCloudPath, expectToExist: true)
			)
		}.then { itemsExist in
			let sourceItemExists = itemsExist[0]
			let targetItemExists = itemsExist[1]
			guard !sourceItemExists, targetItemExists else {
				XCTFail("moveFile did not rename file correctly")
				return
			}
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testMoveFileToDifferentParentFolder() throws {
		let expectation = XCTestExpectation(description: "moveFile can move file to different parent folder")
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FileToMove")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/MoveItemsInThisFolder/renamedAndMovedFile")
		provider.moveFile(from: sourceCloudPath, to: targetCloudPath).then {
			all(
				self.provider.repeatedlyCheckForItemExistence(at: sourceCloudPath, expectToExist: false),
				self.provider.repeatedlyCheckForItemExistence(at: targetCloudPath, expectToExist: true)
			)
		}.then { itemsExist in
			let sourceItemExists = itemsExist[0]
			let targetItemExists = itemsExist[1]
			guard !sourceItemExists, targetItemExists else {
				XCTFail("moveFile did not move file to different parent folder correctly")
				return
			}
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testMoveFileWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "moveFile for nonexistent file")
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/thisFileMustNotExist.pdf")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/MoveItemsInThisFolder/thisFileMustNotExistRenamed.pdf")
		provider.moveFile(from: sourceCloudPath, to: targetCloudPath).then {
			XCTFail("moveFile fulfilled for nonexistent file")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testMoveFileWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "moveFile to already existing file")
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FileForItemAlreadyExists")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FileForItemTypeMismatch")
		provider.moveFile(from: sourceCloudPath, to: targetCloudPath).then {
			XCTFail("moveFile fulfilled to already existing file")
		}.catch { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testMoveFileWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "moveFile to nonexistent parent folder")
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FileForParentFolderDoesNotExist")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/thisFolderMustNotExist/FileForParentFolderDoesNotExists")
		provider.moveFile(from: sourceCloudPath, to: targetCloudPath).then {
			XCTFail("moveFile fulfilled to nonexistent parent folder")
		}.catch { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	// MARK: - moveFolder Tests

	func testMoveFolderAsRename() throws {
		let expectation = XCTestExpectation(description: "moveFolder can rename folder")
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FolderToRename")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/RenamedFolder")
		provider.moveFolder(from: sourceCloudPath, to: targetCloudPath).then {
			all(
				self.provider.repeatedlyCheckForItemExistence(at: sourceCloudPath, expectToExist: false),
				self.provider.repeatedlyCheckForItemExistence(at: targetCloudPath, expectToExist: true)
			)
		}.then { itemsExist in
			let sourceItemExists = itemsExist[0]
			let targetItemExists = itemsExist[1]
			guard !sourceItemExists, targetItemExists else {
				XCTFail("moveFolder did not rename folder correctly")
				return
			}
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testMoveFolderToDifferentParentFolder() throws {
		let expectation = XCTestExpectation(description: "moveFolder can move folder to different parent folder")
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FolderToMove")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/MoveItemsInThisFolder/renamedAndMovedFolder")
		provider.moveFolder(from: sourceCloudPath, to: targetCloudPath).then {
			all(
				self.provider.repeatedlyCheckForItemExistence(at: sourceCloudPath, expectToExist: false),
				self.provider.repeatedlyCheckForItemExistence(at: targetCloudPath, expectToExist: true)
			)
		}.then { itemsExist in
			let sourceItemExists = itemsExist[0]
			let targetItemExists = itemsExist[1]
			guard !sourceItemExists, targetItemExists else {
				XCTFail("moveFolder did not move folder to different parent folder correctly")
				return
			}
		}.catch { error in
			XCTFail(error.localizedDescription)
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testMoveFolderWithNotFoundError() throws {
		let expectation = XCTestExpectation(description: "moveFolder for nonexistent folder")
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/thisFolderMustNotExist")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/MoveItemsInThisFolder/thisFolderMustNotExistRenamed")
		provider.moveFolder(from: sourceCloudPath, to: targetCloudPath).then {
			XCTFail("moveFolder fulfilled for nonexistent folder")
		}.catch { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testMoveFolderWithAlreadyExistsError() throws {
		let expectation = XCTestExpectation(description: "moveFolder to already existing folder")
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FolderForItemAlreadyExists")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FolderForItemTypeMismatch")
		provider.moveFolder(from: sourceCloudPath, to: targetCloudPath).then {
			XCTFail("moveFolder fulfilled although a folder already exists at the target URL")
		}.catch { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	func testMoveFolderWithParentFolderDoesNotExistError() throws {
		let expectation = XCTestExpectation(description: "moveFolder to nonexistent parent folder")
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FolderForParentFolderDoesNotExist")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/thisFolderMustNotExist/FolderForParentFolderDoesNotExist")
		provider.moveFolder(from: sourceCloudPath, to: targetCloudPath).then {
			XCTFail("moveFolder fulfilled to nonexistent parent folder")
		}.catch { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 60.0)
	}

	// MARK: - Helpers

	private func assertReceivedCorrectMetadataAfterUploading(file localURL: URL, to cloudPath: CloudPath, metadata: CloudItemMetadata) {
		let localFileSize: Int?
		do {
			let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
			localFileSize = attributes[FileAttributeKey.size] as? Int
		} catch {
			XCTFail("Get local file size failed with error: \(error)")
			return
		}
		XCTAssertEqual(cloudPath, metadata.cloudPath)
		XCTAssertEqual(cloudPath.lastPathComponent, metadata.name)
		XCTAssertEqual(localFileSize, metadata.size)
		XCTAssertNotNil(metadata.size)
		XCTAssertEqual(.file, metadata.itemType)
	}
}

extension CloudItemMetadata: Comparable {
	public static func < (lhs: CloudItemMetadata, rhs: CloudItemMetadata) -> Bool {
		return lhs.name < rhs.name
	}

	public static func == (lhs: CloudItemMetadata, rhs: CloudItemMetadata) -> Bool {
		return lhs.name == rhs.name && lhs.cloudPath == rhs.cloudPath && lhs.itemType == rhs.itemType
	}
}

extension CloudProvider {
	/**
	 Checks if the item exists at the given cloud path.

	 This method is primarily used as a workaround for providers with eventual consistency. It will repeatedly check if `expectToExist` doesn't match with a delay of 1 second up to a maximum of 3 attempts.
	 */
	func repeatedlyCheckForItemExistence(at cloudPath: CloudPath, expectToExist: Bool, attempt: Int = 0) -> Promise<Bool> {
		return checkForItemExistence(at: cloudPath).then { itemExists in
			if itemExists == expectToExist || attempt == 3 {
				return Promise(itemExists)
			} else {
				return Promise(()).delay(1.0).then {
					return repeatedlyCheckForItemExistence(at: cloudPath, expectToExist: expectToExist, attempt: attempt + 1)
				}
			}
		}
	}
}
