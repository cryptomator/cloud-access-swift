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

class CloudAccessIntegrationTest: XCTestCase {
	static let testContentForFilesInRoot = "testContent"
	static let testContentForFilesInTestFolder = "File inside Folder Content"

	static let runID = String(UUID().uuidString.prefix(8))
	nonisolated(unsafe) static var classSetUpError: Error?
	nonisolated(unsafe) static var setUpProvider: CloudProvider!
	nonisolated(unsafe) static var integrationTestParentCloudPath: CloudPath!
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
		classSetUpError = nil
		precondition(setUpProvider != nil)
		precondition(integrationTestParentCloudPath != nil)
		let provider: CloudProvider = setUpProvider
		let integrationTestRootCloudPath = integrationTestRootCloudPath
		do {
			try blockingAwait(timeout: 180.0) {
				try await setUpForIntegrationTest(at: provider, integrationTestRootCloudPath: integrationTestRootCloudPath)
			}
		} catch {
			classSetUpError = error
		}
	}

	override class func tearDown() {
		guard let provider = setUpProvider else { return }
		let integrationTestRootCloudPath = integrationTestRootCloudPath
		try? blockingAwait(timeout: 60.0) {
			try await provider.deleteFolder(at: integrationTestRootCloudPath)
		}
		setUpProvider = nil
	}

	override func setUp() async throws {
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
	func createLimitedCloudProvider() async throws -> CloudProvider {
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
	private static func setUpForIntegrationTest(at provider: CloudProvider, integrationTestRootCloudPath: CloudPath) async throws {
		let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer {
			try? FileManager.default.removeItem(at: tmpDirURL)
		}
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		try createRootFolderContent(at: tmpDirURL) // locally create the full test directory (incl. all descendants)
		try await deepCopyLocalContentToCloud(from: tmpDirURL, to: integrationTestRootCloudPath, with: provider)
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

	private static func deepCopyLocalContentToCloud(from url: URL, to cloudPath: CloudPath, with provider: CloudProvider) async throws {
		try await provider.deleteFolderIfExisting(at: cloudPath)
		try await provider.createFolderWithIntermediates(for: cloudPath)
		guard let enumerator = FileManager.default.enumerator(atPath: url.path) else {
			throw IntegrationTestError.missingDirectoryEnumerator
		}
		while let nextObject = enumerator.nextObject() as? String {
			let fileURL = url.appendingPathComponent(nextObject)
			var isDirectory: ObjCBool = false
			FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
			let itemCloudPath = cloudPath.appendingPathComponent(nextObject)
			if isDirectory.boolValue {
				try await retryOnEventualConsistencyError { try await provider.createFolder(at: itemCloudPath) }
			} else {
				try await retryOnEventualConsistencyError { _ = try await provider.uploadFile(from: fileURL, to: itemCloudPath, replaceExisting: false) }
			}
		}
	}

	/// Retries an operation that fails due to eventual consistency (e.g. S3).
	/// During setUp, `parentFolderDoesNotExist`, `itemNotFound`, and `itemAlreadyExists` indicate that
	/// a just-created or just-deleted item's state hasn't propagated yet.
	private static func retryOnEventualConsistencyError(maxAttempts: Int = 10, operation: () async throws -> Void) async throws {
		for attempt in 0 ..< maxAttempts {
			do {
				try await operation()
				return
			} catch {
				guard isEventualConsistencyError(error) else {
					throw error
				}
				if attempt == maxAttempts - 1 {
					throw error
				}
				try await Task.sleep(for: .seconds(2))
			}
		}
	}

	private static func isEventualConsistencyError(_ error: Error) -> Bool {
		switch error {
		case CloudProviderError.parentFolderDoesNotExist, CloudProviderError.itemNotFound, CloudProviderError.itemAlreadyExists:
			return true
		default:
			return false
		}
	}

	/// Waits until the test fixtures uploaded by `setUp()` are visible, for providers with eventual consistency (e.g. S3, pCloud).
	/// This is best effort: the tests run even if the fixtures didn't become visible, only a timeout fails the setup.
	static func waitForConsistencyOfSetUp(expectedItemCount: Int) {
		let provider: CloudProvider = setUpProvider
		let integrationTestRootCloudPath = integrationTestRootCloudPath
		do {
			try blockingAwait(timeout: 60.0) {
				try? await waitForConsistency(provider: provider, folderPath: integrationTestRootCloudPath, expectedItemCount: expectedItemCount)
			}
		} catch {
			classSetUpError = error
		}
	}

	/// Polls `fetchItemList` until the expected number of items is visible, retrying up to 10 times with a 1-second delay.
	private static func waitForConsistency(provider: CloudProvider, folderPath: CloudPath, expectedItemCount: Int) async throws {
		var attempt = 0
		while true {
			let itemList = try await provider.fetchItemList(forFolderAt: folderPath, withPageToken: nil)
			if itemList.items.count >= expectedItemCount {
				return
			}
			if attempt >= 10 {
				throw IntegrationTestError.consistencyTimeout
			}
			try await Task.sleep(for: .seconds(1))
			attempt += 1
		}
	}

	/// Waits for a vault's `d/` directory structure to become visible on S3.
	/// Uses the raw S3 provider (not the vault decorator) to avoid partial-state issues
	/// where the vault decorator's `createFolder` is not idempotent on retry.
	/// Validates both `fetchItemList` and `fetchItemMetadata` on `d/` since the vault
	/// decorator's internal `assertParentFolderExists` relies on `fetchItemMetadata`.
	static func waitForVaultReadiness(rawProvider: CloudProvider, vaultPath: CloudPath) async throws {
		let dFolderPath = vaultPath.appendingPathComponent("d")
		var attempt = 0
		while true {
			do {
				let itemList = try await rawProvider.fetchItemList(forFolderAt: dFolderPath, withPageToken: nil)
				guard let firstChild = itemList.items.first else {
					throw CloudProviderError.itemNotFound
				}
				// Also verify that fetchItemMetadata sees both d/ and its first child (e.g. d/AB/).
				// This is the same operation assertParentFolderExists uses internally.
				_ = try await rawProvider.fetchItemMetadata(at: dFolderPath)
				_ = try await rawProvider.fetchItemMetadata(at: firstChild.cloudPath)
				return
			} catch {
				if attempt >= 30 {
					throw IntegrationTestError.consistencyTimeout
				}
				try await Task.sleep(for: .seconds(2))
				attempt += 1
			}
		}
	}

	// MARK: - fetchItemMetadata Tests

	func testFetchItemMetadataForFile() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		let metadata = try await provider.fetchItemMetadata(at: cloudPath)
		XCTAssertEqual("test 0.txt", metadata.name)
		XCTAssertEqual(cloudPath, metadata.cloudPath)
		XCTAssertEqual(CloudItemType.file, metadata.itemType)
	}

	func testFetchItemMetadataForFolder() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder")
		let metadata = try await provider.fetchItemMetadata(at: cloudPath)
		XCTAssertEqual("testFolder", metadata.name)
		XCTAssertEqual(cloudPath, metadata.cloudPath)
		XCTAssertEqual(CloudItemType.folder, metadata.itemType)
	}

	func testFetchItemMetadataForFileWithNotFoundError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("thisFileMustNotExist.pdf")
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: cloudPath), "fetchItemMetadata fulfilled for nonexistent file") { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail("fetchItemMetadata threw the wrong error: \(error)")
				return
			}
		}
	}

	func testFetchItemMetadataForFolderWithNotFoundError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("thisFolderMustNotExist")
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: cloudPath), "fetchItemMetadata fulfilled for nonexistent folder") { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail("fetchItemMetadata threw the wrong error: \(error)")
				return
			}
		}
	}

	func testFetchItemMetadataForFileInSubfolder() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/test 0.txt")
		let metadata = try await provider.fetchItemMetadata(at: cloudPath)
		XCTAssertEqual("test 0.txt", metadata.name)
		XCTAssertEqual(cloudPath, metadata.cloudPath)
		XCTAssertEqual(CloudItemType.file, metadata.itemType)
	}

	func testFetchItemMetadataForFolderInSubfolder() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder")
		let metadata = try await provider.fetchItemMetadata(at: cloudPath)
		XCTAssertEqual("EmptySubfolder", metadata.name)
		XCTAssertEqual(cloudPath, metadata.cloudPath)
		XCTAssertEqual(CloudItemType.folder, metadata.itemType)
	}

	// MARK: - fetchItemList Tests

	func testFetchItemListForRootFolder() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath
		let retrievedItemList = try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil)
		let retrievedSortedItems = retrievedItemList.items.sorted()
		XCTAssertNil(retrievedItemList.nextPageToken)
		XCTAssertEqual(expectedRootFolderItems, retrievedSortedItems)
	}

	func testFetchItemListForSubfolder() async throws {
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
		let retrievedItemList = try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil)
		let retrievedSortedItems = retrievedItemList.items.sorted()
		XCTAssertNil(retrievedItemList.nextPageToken)
		XCTAssertEqual(expectedItems, retrievedSortedItems)
	}

	func testFetchItemListForEmptyFolder() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder")
		let expectedItems = [CloudItemMetadata]()
		let retrievedItemList = try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil)
		let retrievedSortedItems = retrievedItemList.items.sorted()
		XCTAssertNil(retrievedItemList.nextPageToken)
		XCTAssertEqual(expectedItems, retrievedSortedItems)
	}

	func testFetchItemListWithNotFoundError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("thisFolderMustNotExist")
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil), "fetchItemList fulfilled for nonexistent folder") { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail("fetchItemList threw the wrong error: \(error)")
				return
			}
		}
	}

	func testFetchItemListWithTypeMismatchError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil), "fetchItemList fulfilled for file") { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testFetchItemListWithPageTokenInvalidError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath
		await XCTAssertThrowsErrorAsync(try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: "invalidPageToken"), "fetchItemList fulfilled with invalid page token") { error in
			guard case CloudProviderError.pageTokenInvalid = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testFetchItemListPagination() async throws {
		let provider = try await createLimitedCloudProvider()
		let cloudPath = type(of: self).integrationTestRootCloudPath
		let firstItemList = try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil)
		XCTAssertNotNil(firstItemList.nextPageToken)
		XCTAssertEqual(3, firstItemList.items.count)
		let secondItemList = try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: firstItemList.nextPageToken)
		XCTAssertNil(secondItemList.nextPageToken)
		XCTAssertEqual(3, secondItemList.items.count)
		let sortedRetrievedItems = (firstItemList.items + secondItemList.items).sorted()
		XCTAssertEqual(expectedRootFolderItems, sortedRetrievedItems)
	}

	// MARK: - downloadFile Tests

	func testDownloadFileFromRootFolder() async throws {
		let expectedFileContent = type(of: self).testContentForFilesInRoot
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			print("\(progress.localizedDescription ?? "") (\(progress.localizedAdditionalDescription ?? ""))")
		}
		defer {
			progressObserver.invalidate()
		}
		let metadata = try await provider.downloadFile(from: cloudPath, to: localURL, progress: progress, onTaskCreation: nil)
		let actualFileContent = try String(contentsOf: localURL)
		XCTAssertEqual(expectedFileContent, actualFileContent)
		XCTAssertEqual(1.0, progress.fractionCompleted)
		try await assertReceivedCorrectMetadataAfterDownloading(file: localURL, from: cloudPath, metadata: metadata)
	}

	func testDownloadFileFromSubfolder() async throws {
		let expectedFileContent = type(of: self).testContentForFilesInTestFolder
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/test 0.txt")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let progress = Progress(totalUnitCount: 1)
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			print("\(progress.localizedDescription ?? "") (\(progress.localizedAdditionalDescription ?? ""))")
		}
		defer {
			progressObserver.invalidate()
		}
		let metadata = try await provider.downloadFile(from: cloudPath, to: localURL, progress: progress, onTaskCreation: nil)
		let actualFileContent = try String(contentsOf: localURL)
		XCTAssertEqual(expectedFileContent, actualFileContent)
		XCTAssertEqual(1.0, progress.fractionCompleted)
		try await assertReceivedCorrectMetadataAfterDownloading(file: localURL, from: cloudPath, metadata: metadata)
	}

	func testDownloadFileWithNotFoundError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("thisFileMustNotExist.txt")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: cloudPath, to: localURL), "downloadFile fulfilled for nonexistent file") { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testDownloadFileWithAlreadyExistsError() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "".write(to: localURL, atomically: true, encoding: .utf8)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: cloudPath, to: localURL), "downloadFile fulfilled to already existing file") { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testDownloadFileFailWithTypeMismatchError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder")
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: cloudPath, to: localURL), "downloadFile fulfilled for folder") { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	// MARK: - uploadFile Tests

	func testUploadFileWithReplaceExisting() async throws {
		let initialLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let initialTestContent = "Start content"
		try initialTestContent.write(to: initialLocalURL, atomically: true, encoding: .utf8)
		let overwrittenUploadURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let overwrittenLocalURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let overwrittenTestContent = "Overwritten content"
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/FileToOverwrite.txt")
		let progress = Progress(totalUnitCount: 1)
		let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
			print("\(progress.localizedDescription ?? "") (\(progress.localizedAdditionalDescription ?? ""))")
		}
		defer {
			progressObserver.invalidate()
		}
		let initialMetadata = try await provider.uploadFile(from: initialLocalURL, to: cloudPath, replaceExisting: false, progress: progress, onTaskCreation: nil)
		XCTAssertEqual(1.0, progress.fractionCompleted)
		assertReceivedCorrectMetadataAfterUploading(file: initialLocalURL, to: cloudPath, metadata: initialMetadata)
		try overwrittenTestContent.write(to: overwrittenUploadURL, atomically: true, encoding: .utf8)
		let overwrittenMetadata = try await provider.uploadFile(from: overwrittenUploadURL, to: cloudPath, replaceExisting: true)
		assertReceivedCorrectMetadataAfterUploading(file: overwrittenUploadURL, to: cloudPath, metadata: overwrittenMetadata)
		_ = try await provider.downloadFile(from: cloudPath, to: overwrittenLocalURL)
		try await provider.deleteFile(at: cloudPath)
		let downloadedContent = try String(contentsOf: overwrittenLocalURL)
		XCTAssertEqual(overwrittenTestContent, downloadedContent)
	}

	func testUploadFileWithNotFoundError() async {
		let localURL = tmpDirURL.appendingPathComponent("nonExistentFile.txt", isDirectory: false)
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/nonExistentFile.txt")
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false), "uploadFile fulfilled for nonexistent file") { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testUploadFileWithAlreadyExistsErrorAndNotReplaceExisting() async throws {
		let localURL = tmpDirURL.appendingPathComponent("test 0.txt", isDirectory: false)
		let testContent = type(of: self).testContentForFilesInTestFolder
		try testContent.write(to: localURL, atomically: true, encoding: .utf8)
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/test 0.txt")
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false), "uploadFile fulfilled to already existing file without replace existing") { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testUploadFileWithAlreadyExistsErrorAndReplaceExisting() async throws {
		let localURL = tmpDirURL.appendingPathComponent("overwriteFolder.txt", isDirectory: false)
		let testContent = type(of: self).testContentForFilesInTestFolder
		try testContent.write(to: localURL, atomically: true, encoding: .utf8)
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/overwriteFolder.txt")
		try await provider.createFolder(at: cloudPath)
		// Delay to allow eventual consistency propagation (e.g. S3, pCloud) so that
		// uploadFile's pre-upload existence check can detect the just-created folder.
		try await Task.sleep(for: .seconds(5))
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: true), "uploadFile fulfilled to already existing folder with replace existing") { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testUploadFileWithParentFolderDoesNotExistError() async throws {
		let localURL = tmpDirURL.appendingPathComponent("test 0.txt", isDirectory: false)
		let testContent = type(of: self).testContentForFilesInTestFolder
		try testContent.write(to: localURL, atomically: true, encoding: .utf8)
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/thisFolderMustNotExist/test 0.txt")
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false), "uploadFile fulfilled to nonexistent parent folder") { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testUploadFileWithTypeMismatchError() async throws {
		let localURL = tmpDirURL.appendingPathComponent("itemTypeMismatchFolder", isDirectory: false)
		try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false, attributes: nil)
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("itemTypeMismatchFolder")
		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false), "uploadFile fulfilled for folder") { error in
			guard case CloudProviderError.itemTypeMismatch = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	// MARK: - createFolder Tests

	func testCreateFolderForFolderWithAlreadyExistsError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder")
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: cloudPath), "createFolder fulfilled for already existing folder") { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testCreateFolderForFileWithAlreadyExistsError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: cloudPath), "createFolder fulfilled for already existing file") { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testCreateFolderWithParentFolderDoesNotExistError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("thisFolderMustNotExist-AAA").appendingPathComponent("folderToCreate")
		await XCTAssertThrowsErrorAsync(try await provider.createFolder(at: cloudPath), "createFolder fulfilled to nonexistent parent folder") { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	// MARK: - deleteFile Tests

	func testDeleteFile() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForDeleteItems/FileToDelete")
		try await provider.deleteFile(at: cloudPath)
		let fileExists = try await provider.repeatedlyCheckForItemExistence(at: cloudPath, expectToExist: false)
		guard !fileExists else {
			XCTFail("File still exists in the cloud")
			return
		}
	}

	func testDeleteFileWithNotFoundError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForDeleteItems/thisFileMustNotExist")
		await XCTAssertThrowsErrorAsync(try await provider.deleteFile(at: cloudPath), "deleteFile fulfilled for nonexistent file") { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	// MARK: - deleteFolder Tests

	func testDeleteFolderCanDeleteExistingFolder() async throws {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForDeleteItems/FolderToDelete")
		try await provider.deleteFolder(at: cloudPath)
		let folderExists = try await provider.repeatedlyCheckForItemExistence(at: cloudPath, expectToExist: false)
		guard !folderExists else {
			XCTFail("Folder still exists in the cloud")
			return
		}
	}

	func testDeleteFolderWithNotFoundError() async {
		let cloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForDeleteItems/thisFolderMustNotExist")
		await XCTAssertThrowsErrorAsync(try await provider.deleteFolder(at: cloudPath), "deleteFolder fulfilled for nonexistent folder") { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	// MARK: - moveFile Tests

	func testMoveFileAsRename() async throws {
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FileToRename")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/RenamedFile")
		try await provider.moveFile(from: sourceCloudPath, to: targetCloudPath)
		let sourceItemExists = try await provider.repeatedlyCheckForItemExistence(at: sourceCloudPath, expectToExist: false)
		let targetItemExists = try await provider.repeatedlyCheckForItemExistence(at: targetCloudPath, expectToExist: true)
		guard !sourceItemExists, targetItemExists else {
			XCTFail("moveFile did not rename file correctly")
			return
		}
	}

	func testMoveFileToDifferentParentFolder() async throws {
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FileToMove")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/MoveItemsInThisFolder/renamedAndMovedFile")
		try await provider.moveFile(from: sourceCloudPath, to: targetCloudPath)
		let sourceItemExists = try await provider.repeatedlyCheckForItemExistence(at: sourceCloudPath, expectToExist: false)
		let targetItemExists = try await provider.repeatedlyCheckForItemExistence(at: targetCloudPath, expectToExist: true)
		guard !sourceItemExists, targetItemExists else {
			XCTFail("moveFile did not move file to different parent folder correctly")
			return
		}
	}

	func testMoveFileWithNotFoundError() async {
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/thisFileMustNotExist.pdf")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/MoveItemsInThisFolder/thisFileMustNotExistRenamed.pdf")
		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: sourceCloudPath, to: targetCloudPath), "moveFile fulfilled for nonexistent file") { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testMoveFileWithAlreadyExistsError() async {
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FileForItemAlreadyExists")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FileForItemTypeMismatch")
		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: sourceCloudPath, to: targetCloudPath), "moveFile fulfilled to already existing file") { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testMoveFileWithParentFolderDoesNotExistError() async {
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FileForParentFolderDoesNotExist")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/thisFolderMustNotExist/FileForParentFolderDoesNotExists")
		await XCTAssertThrowsErrorAsync(try await provider.moveFile(from: sourceCloudPath, to: targetCloudPath), "moveFile fulfilled to nonexistent parent folder") { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	// MARK: - moveFolder Tests

	func testMoveFolderAsRename() async throws {
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FolderToRename")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/RenamedFolder")
		try await provider.moveFolder(from: sourceCloudPath, to: targetCloudPath)
		let sourceItemExists = try await provider.repeatedlyCheckForItemExistence(at: sourceCloudPath, expectToExist: false)
		let targetItemExists = try await provider.repeatedlyCheckForItemExistence(at: targetCloudPath, expectToExist: true)
		guard !sourceItemExists, targetItemExists else {
			XCTFail("moveFolder did not rename folder correctly")
			return
		}
	}

	func testMoveFolderToDifferentParentFolder() async throws {
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FolderToMove")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/MoveItemsInThisFolder/renamedAndMovedFolder")
		try await provider.moveFolder(from: sourceCloudPath, to: targetCloudPath)
		let sourceItemExists = try await provider.repeatedlyCheckForItemExistence(at: sourceCloudPath, expectToExist: false)
		let targetItemExists = try await provider.repeatedlyCheckForItemExistence(at: targetCloudPath, expectToExist: true)
		guard !sourceItemExists, targetItemExists else {
			XCTFail("moveFolder did not move folder to different parent folder correctly")
			return
		}
	}

	func testMoveFolderWithNotFoundError() async {
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/thisFolderMustNotExist")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/MoveItemsInThisFolder/thisFolderMustNotExistRenamed")
		await XCTAssertThrowsErrorAsync(try await provider.moveFolder(from: sourceCloudPath, to: targetCloudPath), "moveFolder fulfilled for nonexistent folder") { error in
			guard case CloudProviderError.itemNotFound = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testMoveFolderWithAlreadyExistsError() async {
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FolderForItemAlreadyExists")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FolderForItemTypeMismatch")
		await XCTAssertThrowsErrorAsync(try await provider.moveFolder(from: sourceCloudPath, to: targetCloudPath), "moveFolder fulfilled although a folder already exists at the target URL") { error in
			guard case CloudProviderError.itemAlreadyExists = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	func testMoveFolderWithParentFolderDoesNotExistError() async {
		let sourceCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/FolderForParentFolderDoesNotExist")
		let targetCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/FolderForMoveItems/thisFolderMustNotExist/FolderForParentFolderDoesNotExist")
		await XCTAssertThrowsErrorAsync(try await provider.moveFolder(from: sourceCloudPath, to: targetCloudPath), "moveFolder fulfilled to nonexistent parent folder") { error in
			guard case CloudProviderError.parentFolderDoesNotExist = error else {
				XCTFail(error.localizedDescription)
				return
			}
		}
	}

	// MARK: - Helpers

	/**
	 Asserts that operations started in an already cancelled task throw `CancellationError` without leaving anything behind.
	 */
	func assertOperationsThrowCancellationErrorInCancelledTask() async throws {
		let provider: CloudProvider = provider
		let existingFileCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("test 0.txt")
		let uploadCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/cancelledFile.txt")
		let folderCloudPath = type(of: self).integrationTestRootCloudPath.appendingPathComponent("testFolder/EmptySubfolder/cancelledFolder")
		let uploadURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try type(of: self).testContentForFilesInTestFolder.write(to: uploadURL, atomically: true, encoding: .utf8)
		let downloadURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let operations: [(String, @Sendable () async throws -> Void)] = [
			("fetchItemMetadata", { _ = try await provider.fetchItemMetadata(at: existingFileCloudPath) }),
			("uploadFile", { _ = try await provider.uploadFile(from: uploadURL, to: uploadCloudPath, replaceExisting: false) }),
			("downloadFile", { _ = try await provider.downloadFile(from: existingFileCloudPath, to: downloadURL) }),
			("createFolder", { try await provider.createFolder(at: folderCloudPath) })
		]
		for (name, operation) in operations {
			await XCTAssertThrowsErrorAsync(try await value(of: cancelledTask(operation), timeout: 60.0), "\(name) did not throw") { error in
				XCTAssertTrue(error is CancellationError, "\(name) threw \(error)")
			}
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: downloadURL.path))
		let uploadedFileExists = try await provider.checkForItemExistence(at: uploadCloudPath)
		XCTAssertFalse(uploadedFileExists)
		let createdFolderExists = try await provider.checkForItemExistence(at: folderCloudPath)
		XCTAssertFalse(createdFolderExists)
	}

	private func assertReceivedCorrectMetadataAfterDownloading(file localURL: URL, from cloudPath: CloudPath, metadata: CloudItemMetadata) async throws {
		let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
		let localFileSize = attributes[FileAttributeKey.size] as? Int
		XCTAssertEqual(cloudPath, metadata.cloudPath)
		XCTAssertEqual(cloudPath.lastPathComponent, metadata.name)
		XCTAssertEqual(localFileSize, metadata.size)
		XCTAssertNotNil(metadata.size)
		XCTAssertEqual(.file, metadata.itemType)
		let expectedLastModifiedDate = try await provider.fetchItemMetadata(at: cloudPath).lastModifiedDate
		XCTAssertEqual(expectedLastModifiedDate.map { floor($0.timeIntervalSince1970) }, metadata.lastModifiedDate.map { floor($0.timeIntervalSince1970) })
	}

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

	 This method is primarily used as a workaround for providers with eventual consistency. It will repeatedly check if `expectToExist` doesn't match with a delay of 2 seconds up to 10 retries (11 total checks).
	 */
	func repeatedlyCheckForItemExistence(at cloudPath: CloudPath, expectToExist: Bool) async throws -> Bool {
		var attempt = 0
		while true {
			let itemExists = try await checkForItemExistence(at: cloudPath)
			if itemExists == expectToExist || attempt == 10 {
				return itemExists
			}
			try await Task.sleep(for: .seconds(2))
			attempt += 1
		}
	}
}
