//
//  CloudProviderConformanceTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 29.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import Foundation
import Testing

/**
 Tests every backend against the specification of the `CloudProvider` protocol.

 Tests read the tree of the fixture, see `IntegrationFixture`, and make their changes in a sandbox of their own. They issue their remote calls before they check the results, because a failed expectation stays recorded when a later transient error retries the test.
 */
extension IntegrationTests {
	struct Conformance {
		// MARK: - fetchItemMetadata Tests

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemMetadataForFile(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("test 0.txt")
				let metadata = try await context.provider.fetchItemMetadata(at: cloudPath)
				#expect(metadata.name == "test 0.txt")
				#expect(metadata.cloudPath == cloudPath)
				#expect(metadata.itemType == .file)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemMetadataForFolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder")
				let metadata = try await context.provider.fetchItemMetadata(at: cloudPath)
				#expect(metadata.name == "testFolder")
				#expect(metadata.cloudPath == cloudPath)
				#expect(metadata.itemType == .folder)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemMetadataForFileWithNotFoundError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("thisFileMustNotExist.pdf")
				try await expectCloudProviderError(.itemNotFound) { try await context.provider.fetchItemMetadata(at: cloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemMetadataForFolderWithNotFoundError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("thisFolderMustNotExist")
				try await expectCloudProviderError(.itemNotFound) { try await context.provider.fetchItemMetadata(at: cloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemMetadataForFileInSubfolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder/test 0.txt")
				let metadata = try await context.provider.fetchItemMetadata(at: cloudPath)
				#expect(metadata.name == "test 0.txt")
				#expect(metadata.cloudPath == cloudPath)
				#expect(metadata.itemType == .file)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemMetadataForFolderInSubfolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder/EmptySubfolder")
				let metadata = try await context.provider.fetchItemMetadata(at: cloudPath)
				#expect(metadata.name == "EmptySubfolder")
				#expect(metadata.cloudPath == cloudPath)
				#expect(metadata.itemType == .folder)
			}
		}

		// MARK: - fetchItemList Tests

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemListForRootFolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let itemList = try await context.provider.fetchItemList(forFolderAt: context.treeRoot, withPageToken: nil)
				#expect(itemList.nextPageToken == nil)
				#expect(itemList.items.sorted() == Conformance.expectedRootFolderItems(in: context))
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemListForSubfolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder")
				let itemList = try await context.provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil)
				#expect(itemList.nextPageToken == nil)
				#expect(itemList.items.sorted() == Conformance.expectedTestFolderItems(in: context))
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemListForEmptyFolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder/EmptySubfolder")
				let itemList = try await context.provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil)
				#expect(itemList.nextPageToken == nil)
				#expect(itemList.items.isEmpty)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemListWithNotFoundError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("thisFolderMustNotExist")
				try await expectCloudProviderError(.itemNotFound) { try await context.provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemListWithTypeMismatchError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("test 0.txt")
				try await expectCloudProviderError(.itemTypeMismatch) { try await context.provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func fetchItemListWithPageTokenInvalidError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				try await expectCloudProviderError(.pageTokenInvalid) { try await context.provider.fetchItemList(forFolderAt: context.treeRoot, withPageToken: "invalidPageToken") }
			}
		}

		/// A page can hold fewer items than the page size, because a vault backend leaves out what isn't an item of the vault, e.g. the `dirid.c9r` of vault format 8.
		@Test(arguments: IntegrationBackend.selected)
		func fetchItemListPagination(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let provider = try context.makeLimitedProvider()
				let firstItemList = try await provider.fetchItemList(forFolderAt: context.treeRoot, withPageToken: nil)
				let itemLists = try await [firstItemList] + Conformance.remainingItemLists(after: firstItemList, forFolderAt: context.treeRoot, through: provider)
				#expect(firstItemList.nextPageToken != nil)
				#expect(itemLists.allSatisfy { $0.items.count <= IntegrationFixtures.maxPageSizeForLimitedProvider })
				#expect(itemLists.flatMap(\.items).sorted() == Conformance.expectedRootFolderItems(in: context))
			}
		}

		/// Lists `testFolder`, which no other test lists with the limited provider, so that the listings and retries of other tests can't invalidate its page token.
		@Test(arguments: IntegrationBackend.selected)
		func fetchItemListInterleavedWithAnotherListingOfTheSameFolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let provider = try context.makeLimitedProvider()
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder")
				let firstItemList = try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil)
				let otherItemList = try await provider.fetchItemListExhaustively(forFolderAt: cloudPath)
				let itemLists = try await [firstItemList] + Conformance.remainingItemLists(after: firstItemList, forFolderAt: cloudPath, through: provider)
				#expect(firstItemList.nextPageToken != nil)
				#expect(itemLists.allSatisfy { $0.items.count <= IntegrationFixtures.maxPageSizeForLimitedProvider })
				#expect(itemLists.flatMap(\.items).sorted() == Conformance.expectedTestFolderItems(in: context))
				#expect(otherItemList.items.sorted() == Conformance.expectedTestFolderItems(in: context))
			}
		}

		// MARK: - downloadFile Tests

		@Test(arguments: IntegrationBackend.selected)
		func downloadFileFromRootFolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("test 0.txt")
				try await Conformance.expectDownload(from: cloudPath, toHave: IntegrationFixture.testContentForFilesInRoot, in: context)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func downloadFileFromSubfolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder/test 0.txt")
				try await Conformance.expectDownload(from: cloudPath, toHave: IntegrationFixture.testContentForFilesInTestFolder, in: context)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func downloadFileWithNotFoundError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("thisFileMustNotExist.txt")
				let localURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				try await expectCloudProviderError(.itemNotFound) { try await context.provider.downloadFile(from: cloudPath, to: localURL) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func downloadFileWithAlreadyExistsError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("test 0.txt")
				let localURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				try "".write(to: localURL, atomically: true, encoding: .utf8)
				try await expectCloudProviderError(.itemAlreadyExists) { try await context.provider.downloadFile(from: cloudPath, to: localURL) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func downloadFileFailWithTypeMismatchError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder")
				let localURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				try await expectCloudProviderError(.itemTypeMismatch) { try await context.provider.downloadFile(from: cloudPath, to: localURL) }
			}
		}

		// MARK: - uploadFile Tests

		@Test(arguments: IntegrationBackend.selected)
		func uploadFileWithReplaceExisting(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let initialLocalURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				try "Start content".write(to: initialLocalURL, atomically: true, encoding: .utf8)
				let overwrittenUploadURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				let overwrittenTestContent = "Overwritten content"
				try overwrittenTestContent.write(to: overwrittenUploadURL, atomically: true, encoding: .utf8)
				let overwrittenLocalURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				let cloudPath = try await context.makeSandbox().appendingPathComponent("FileToOverwrite.txt")
				let progress = Progress(totalUnitCount: 1)
				let initialMetadata = try await context.provider.uploadFile(from: initialLocalURL, to: cloudPath, replaceExisting: false, progress: progress, onTaskCreation: nil)
				let overwrittenMetadata = try await context.provider.uploadFile(from: overwrittenUploadURL, to: cloudPath, replaceExisting: true)
				_ = try await context.provider.downloadFile(from: cloudPath, to: overwrittenLocalURL)
				#expect(progress.fractionCompleted == 1.0)
				try Conformance.expectMetadata(initialMetadata, ofFile: initialLocalURL, at: cloudPath)
				try Conformance.expectMetadata(overwrittenMetadata, ofFile: overwrittenUploadURL, at: cloudPath)
				#expect(try String(contentsOf: overwrittenLocalURL, encoding: .utf8) == overwrittenTestContent)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func uploadFileWithNotFoundError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let localURL = context.tmpDirURL.appendingPathComponent("nonExistentFile.txt", isDirectory: false)
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder/EmptySubfolder/nonExistentFile.txt")
				try await expectCloudProviderError(.itemNotFound) { try await context.provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func uploadFileWithAlreadyExistsErrorAndNotReplaceExisting(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let localURL = context.tmpDirURL.appendingPathComponent("test 0.txt", isDirectory: false)
				try IntegrationFixture.testContentForFilesInTestFolder.write(to: localURL, atomically: true, encoding: .utf8)
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder/test 0.txt")
				try await expectCloudProviderError(.itemAlreadyExists) { try await context.provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func uploadFileWithAlreadyExistsErrorAndReplaceExisting(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let localURL = context.tmpDirURL.appendingPathComponent("overwriteFolder.txt", isDirectory: false)
				try IntegrationFixture.testContentForFilesInTestFolder.write(to: localURL, atomically: true, encoding: .utf8)
				let cloudPath = try await context.makeSandbox().appendingPathComponent("overwriteFolder.txt")
				try await context.createPrerequisiteFolder(at: cloudPath)
				try await expectCloudProviderError(.itemAlreadyExists) { try await context.provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: true) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func uploadFileWithParentFolderDoesNotExistError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let localURL = context.tmpDirURL.appendingPathComponent("test 0.txt", isDirectory: false)
				try IntegrationFixture.testContentForFilesInTestFolder.write(to: localURL, atomically: true, encoding: .utf8)
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder/thisFolderMustNotExist/test 0.txt")
				try await expectCloudProviderError(.parentFolderDoesNotExist) { try await context.provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func uploadFileWithTypeMismatchError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let localURL = context.tmpDirURL.appendingPathComponent("itemTypeMismatchFolder", isDirectory: false)
				try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: false)
				let cloudPath = context.treeRoot.appendingPathComponent("itemTypeMismatchFolder")
				try await expectCloudProviderError(.itemTypeMismatch) { try await context.provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false) }
			}
		}

		// MARK: - createFolder Tests

		@Test(arguments: IntegrationBackend.selected)
		func createFolderForFolderWithAlreadyExistsError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder/EmptySubfolder")
				try await expectCloudProviderError(.itemAlreadyExists) { try await context.provider.createFolder(at: cloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func createFolderForFileWithAlreadyExistsError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("test 0.txt")
				try await expectCloudProviderError(.itemAlreadyExists) { try await context.provider.createFolder(at: cloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func createFolderWithParentFolderDoesNotExistError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("thisFolderMustNotExist-AAA/folderToCreate")
				try await expectCloudProviderError(.parentFolderDoesNotExist) { try await context.provider.createFolder(at: cloudPath) }
			}
		}

		// MARK: - deleteFile Tests

		@Test(arguments: IntegrationBackend.selected)
		func deleteFile(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = try await context.makeSandbox().appendingPathComponent("FileToDelete")
				try await context.uploadPrerequisite(Conformance.testContentForSandboxItems, to: cloudPath)
				try await context.provider.deleteFile(at: cloudPath)
				let fileIsGone = try await eventually(on: backend.kind) { try await !context.provider.checkForItemExistence(at: cloudPath) }
				#expect(fileIsGone, "File still exists in the cloud")
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func deleteFileWithNotFoundError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder/thisFileMustNotExist")
				try await expectCloudProviderError(.itemNotFound) { try await context.provider.deleteFile(at: cloudPath) }
			}
		}

		// MARK: - deleteFolder Tests

		@Test(arguments: IntegrationBackend.selected)
		func deleteFolderCanDeleteExistingFolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = try await context.makeSandbox().appendingPathComponent("FolderToDelete")
				try await context.createPrerequisiteFolder(at: cloudPath)
				try await context.provider.deleteFolder(at: cloudPath)
				let folderIsGone = try await eventually(on: backend.kind) { try await !context.provider.checkForItemExistence(at: cloudPath) }
				#expect(folderIsGone, "Folder still exists in the cloud")
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func deleteFolderWithNotFoundError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder/thisFolderMustNotExist")
				try await expectCloudProviderError(.itemNotFound) { try await context.provider.deleteFolder(at: cloudPath) }
			}
		}

		// MARK: - moveFile Tests

		@Test(arguments: IntegrationBackend.selected)
		func moveFileAsRename(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sandbox = try await context.makeSandbox()
				let sourceCloudPath = sandbox.appendingPathComponent("FileToRename")
				let targetCloudPath = sandbox.appendingPathComponent("RenamedFile")
				try await context.uploadPrerequisite(Conformance.testContentForSandboxItems, to: sourceCloudPath)
				try await context.provider.moveFile(from: sourceCloudPath, to: targetCloudPath)
				try await Conformance.expectMove(from: sourceCloudPath, to: targetCloudPath, in: context)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func moveFileToDifferentParentFolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sandbox = try await context.makeSandbox()
				let sourceCloudPath = sandbox.appendingPathComponent("FileToMove")
				let targetParentCloudPath = sandbox.appendingPathComponent("MoveItemsInThisFolder")
				let targetCloudPath = targetParentCloudPath.appendingPathComponent("renamedAndMovedFile")
				try await context.uploadPrerequisite(Conformance.testContentForSandboxItems, to: sourceCloudPath)
				try await context.createPrerequisiteFolder(at: targetParentCloudPath)
				try await context.provider.moveFile(from: sourceCloudPath, to: targetCloudPath)
				try await Conformance.expectMove(from: sourceCloudPath, to: targetCloudPath, in: context)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func moveFileWithNotFoundError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sourceCloudPath = context.treeRoot.appendingPathComponent("testFolder/thisFileMustNotExist")
				let targetCloudPath = context.treeRoot.appendingPathComponent("testFolder/EmptySubfolder/thisFileMustNotExistRenamed")
				try await expectCloudProviderError(.itemNotFound) { try await context.provider.moveFile(from: sourceCloudPath, to: targetCloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func moveFileWithAlreadyExistsError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sandbox = try await context.makeSandbox()
				let sourceCloudPath = sandbox.appendingPathComponent("FileForItemAlreadyExists")
				let targetCloudPath = sandbox.appendingPathComponent("FileForItemTypeMismatch")
				try await context.uploadPrerequisite(Conformance.testContentForSandboxItems, to: sourceCloudPath)
				try await context.uploadPrerequisite(Conformance.testContentForSandboxItems, to: targetCloudPath)
				try await expectCloudProviderError(.itemAlreadyExists) { try await context.provider.moveFile(from: sourceCloudPath, to: targetCloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func moveFileWithParentFolderDoesNotExistError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sandbox = try await context.makeSandbox()
				let sourceCloudPath = sandbox.appendingPathComponent("FileForParentFolderDoesNotExist")
				let targetCloudPath = sandbox.appendingPathComponent("thisFolderMustNotExist/FileForParentFolderDoesNotExists")
				try await context.uploadPrerequisite(Conformance.testContentForSandboxItems, to: sourceCloudPath)
				try await expectCloudProviderError(.parentFolderDoesNotExist) { try await context.provider.moveFile(from: sourceCloudPath, to: targetCloudPath) }
			}
		}

		// MARK: - moveFolder Tests

		@Test(arguments: IntegrationBackend.selected)
		func moveFolderAsRename(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sandbox = try await context.makeSandbox()
				let sourceCloudPath = sandbox.appendingPathComponent("FolderToRename")
				let targetCloudPath = sandbox.appendingPathComponent("RenamedFolder")
				try await context.createPrerequisiteFolder(at: sourceCloudPath)
				try await context.provider.moveFolder(from: sourceCloudPath, to: targetCloudPath)
				try await Conformance.expectMove(from: sourceCloudPath, to: targetCloudPath, in: context)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func moveFolderToDifferentParentFolder(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sandbox = try await context.makeSandbox()
				let sourceCloudPath = sandbox.appendingPathComponent("FolderToMove")
				let targetParentCloudPath = sandbox.appendingPathComponent("MoveItemsInThisFolder")
				let targetCloudPath = targetParentCloudPath.appendingPathComponent("renamedAndMovedFolder")
				try await context.createPrerequisiteFolder(at: sourceCloudPath)
				try await context.createPrerequisiteFolder(at: targetParentCloudPath)
				try await context.provider.moveFolder(from: sourceCloudPath, to: targetCloudPath)
				try await Conformance.expectMove(from: sourceCloudPath, to: targetCloudPath, in: context)
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func moveFolderWithNotFoundError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sourceCloudPath = context.treeRoot.appendingPathComponent("testFolder/thisFolderMustNotExist")
				let targetCloudPath = context.treeRoot.appendingPathComponent("testFolder/EmptySubfolder/thisFolderMustNotExistRenamed")
				try await expectCloudProviderError(.itemNotFound) { try await context.provider.moveFolder(from: sourceCloudPath, to: targetCloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func moveFolderWithAlreadyExistsError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sandbox = try await context.makeSandbox()
				let sourceCloudPath = sandbox.appendingPathComponent("FolderForItemAlreadyExists")
				let targetCloudPath = sandbox.appendingPathComponent("FolderForItemTypeMismatch")
				try await context.createPrerequisiteFolder(at: sourceCloudPath)
				try await context.createPrerequisiteFolder(at: targetCloudPath)
				try await expectCloudProviderError(.itemAlreadyExists) { try await context.provider.moveFolder(from: sourceCloudPath, to: targetCloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selected)
		func moveFolderWithParentFolderDoesNotExistError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sandbox = try await context.makeSandbox()
				let sourceCloudPath = sandbox.appendingPathComponent("FolderForParentFolderDoesNotExist")
				let targetCloudPath = sandbox.appendingPathComponent("thisFolderMustNotExist/FolderForParentFolderDoesNotExist")
				try await context.createPrerequisiteFolder(at: sourceCloudPath)
				try await expectCloudProviderError(.parentFolderDoesNotExist) { try await context.provider.moveFolder(from: sourceCloudPath, to: targetCloudPath) }
			}
		}

		// MARK: - Unauthorized Tests

		@Test(arguments: IntegrationBackend.selectedPlainRemote)
		func fetchItemMetadataWithUnauthorizedError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("test 0.txt")
				let provider = try await context.makeUnauthorizedProvider()
				try await expectCloudProviderError(.unauthorized) { try await provider.fetchItemMetadata(at: cloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selectedPlainRemote)
		func fetchItemListWithUnauthorizedError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("testFolder")
				let provider = try await context.makeUnauthorizedProvider()
				try await expectCloudProviderError(.unauthorized) { try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: nil) }
			}
		}

		@Test(arguments: IntegrationBackend.selectedPlainRemote)
		func downloadFileWithUnauthorizedError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.treeRoot.appendingPathComponent("test 0.txt")
				let localURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				let provider = try await context.makeUnauthorizedProvider()
				try await expectCloudProviderError(.unauthorized) { try await provider.downloadFile(from: cloudPath, to: localURL) }
			}
		}

		@Test(arguments: IntegrationBackend.selectedPlainRemote)
		func uploadFileWithUnauthorizedError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let localURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				try IntegrationFixture.testContentForFilesInTestFolder.write(to: localURL, atomically: true, encoding: .utf8)
				let cloudPath = context.sandboxPath()
				let provider = try await context.makeUnauthorizedProvider()
				try await expectCloudProviderError(.unauthorized) { try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false) }
			}
		}

		@Test(arguments: IntegrationBackend.selectedPlainRemote)
		func createFolderWithUnauthorizedError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.sandboxPath()
				let provider = try await context.makeUnauthorizedProvider()
				try await expectCloudProviderError(.unauthorized) { try await provider.createFolder(at: cloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selectedPlainRemote)
		func deleteFileWithUnauthorizedError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.sandboxPath()
				let provider = try await context.makeUnauthorizedProvider()
				try await expectCloudProviderError(.unauthorized) { try await provider.deleteFile(at: cloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selectedPlainRemote)
		func deleteFolderWithUnauthorizedError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let cloudPath = context.sandboxPath()
				let provider = try await context.makeUnauthorizedProvider()
				try await expectCloudProviderError(.unauthorized) { try await provider.deleteFolder(at: cloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selectedPlainRemote)
		func moveFileWithUnauthorizedError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sourceCloudPath = context.sandboxPath()
				let targetCloudPath = context.sandboxPath()
				let provider = try await context.makeUnauthorizedProvider()
				try await expectCloudProviderError(.unauthorized) { try await provider.moveFile(from: sourceCloudPath, to: targetCloudPath) }
			}
		}

		@Test(arguments: IntegrationBackend.selectedPlainRemote)
		func moveFolderWithUnauthorizedError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sourceCloudPath = context.sandboxPath()
				let targetCloudPath = context.sandboxPath()
				let provider = try await context.makeUnauthorizedProvider()
				try await expectCloudProviderError(.unauthorized) { try await provider.moveFolder(from: sourceCloudPath, to: targetCloudPath) }
			}
		}

		// MARK: - Cancellation Tests

		/// Operations started in an already cancelled task throw `CancellationError` without leaving anything behind.
		@Test(arguments: IntegrationBackend.selectedPlain)
		func operationsInCancelledTaskThrowCancellationError(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let provider = context.provider
				let sandbox = try await context.makeSandbox()
				let existingFileCloudPath = context.treeRoot.appendingPathComponent("test 0.txt")
				let uploadCloudPath = sandbox.appendingPathComponent("cancelledFile.txt")
				let folderCloudPath = sandbox.appendingPathComponent("cancelledFolder")
				let uploadURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				try IntegrationFixture.testContentForFilesInTestFolder.write(to: uploadURL, atomically: true, encoding: .utf8)
				let downloadURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				let operations: [(String, @Sendable () async throws -> Void)] = [
					("fetchItemMetadata", { _ = try await provider.fetchItemMetadata(at: existingFileCloudPath) }),
					("uploadFile", { _ = try await provider.uploadFile(from: uploadURL, to: uploadCloudPath, replaceExisting: false) }),
					("downloadFile", { _ = try await provider.downloadFile(from: existingFileCloudPath, to: downloadURL) }),
					("createFolder", { try await provider.createFolder(at: folderCloudPath) })
				]
				var results = [(String, Result<Void, Error>)]()
				for (name, operation) in operations {
					do {
						try await value(of: cancelledTask(operation), timeout: .seconds(60))
						results.append((name, .success(())))
					} catch {
						results.append((name, .failure(error)))
					}
				}
				let uploadedFileExists = try await provider.checkForItemExistence(at: uploadCloudPath)
				let createdFolderExists = try await provider.checkForItemExistence(at: folderCloudPath)
				for (name, result) in results {
					switch result {
					case .success:
						Issue.record("\(name) did not throw")
					case let .failure(error):
						#expect(error is CancellationError, "\(name) threw \(error)")
					}
				}
				#expect(!FileManager.default.fileExists(atPath: downloadURL.path))
				#expect(!uploadedFileExists)
				#expect(!createdFolderExists)
			}
		}

		// MARK: - Vault Tests

		@Test(arguments: IntegrationBackend.selectedVaults)
		func openVaultWithPassword(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let provider = try await context.openVault()
				let itemList = try await provider.fetchItemListExhaustively(forFolderAt: context.treeRoot)
				#expect(itemList.items.sorted() == Conformance.expectedRootFolderItems(in: context))
			}
		}

		/**
		 A provider that was called with a long path has its shortened name cached, so the listing uses a new provider, which has to restore the names from the name files.
		 */
		@Test(arguments: IntegrationBackend.selectedVaults)
		func itemsWithLongNamesAreShortened(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let format = backend.format
				let sandbox = try await context.makeSandbox()
				let folderPath = sandbox.appendingPathComponent(String(repeating: "d", count: 200))
				let filePath = sandbox.appendingPathComponent(String(repeating: "f", count: 200))
				let localURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				try Conformance.testContentForSandboxItems.write(to: localURL, atomically: true, encoding: .utf8)
				let downloadURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				let (writer, writerRecorder) = try context.makeRecordingProvider()

				try await writer.createFolder(at: folderPath)
				_ = try await writer.uploadFile(from: localURL, to: filePath, replaceExisting: false)
				try await Conformance.waitUntilCreatedItemsAreVisible(of: writerRecorder, in: context)
				let uploadedPaths = writerRecorder.paths(of: .uploadFile)
				let createdShortenedNames = Set((writerRecorder.paths(of: .createFolder) + uploadedPaths).compactMap { Conformance.shortenedName(in: $0, of: format) })
				let uploadedNameFiles = Set(uploadedPaths.compactMap { Conformance.shortenedName(ofNameFileAt: $0, of: format) })
				// The decorator ignores a failed upload of `dirid.c9r`, so only the recorder shows whether it was uploaded.
				let uploadedDirIdFile = uploadedPaths.contains { $0.lastPathComponent == "dirid.c9r" }
				let listing = try await Conformance.coldListing(of: sandbox, expecting: [folderPath, filePath], in: context)
				let downloadedNameFiles = Set(listing.recorder.paths(of: .downloadFile).compactMap { Conformance.shortenedName(ofNameFileAt: $0, of: format) })
				let folderMetadata = try await listing.provider.fetchItemMetadata(at: folderPath)
				let fileMetadata = try await listing.provider.fetchItemMetadata(at: filePath)
				_ = try await listing.provider.downloadFile(from: filePath, to: downloadURL)

				#expect(createdShortenedNames.count == 2, "The folder and the file weren't created at shortened names")
				#expect(uploadedNameFiles == createdShortenedNames)
				#expect(uploadedDirIdFile == (format == .vf8))
				#expect(listing.cloudPaths == [folderPath, filePath])
				#expect(downloadedNameFiles == createdShortenedNames, "The listing didn't restore the names from the name files")
				#expect(folderMetadata.cloudPath == folderPath)
				#expect(folderMetadata.itemType == .folder)
				#expect(fileMetadata.cloudPath == filePath)
				#expect(fileMetadata.itemType == .file)
				#expect(try String(contentsOf: downloadURL, encoding: .utf8) == Conformance.testContentForSandboxItems)
			}
		}

		/// Moves a file from a shortened name to another one and on to an unshortened one, and deletes a folder with a shortened name. Every listing uses a new provider, so the listings after the moves have to restore the names from the name files.
		@Test(arguments: IntegrationBackend.selectedVaults)
		func itemsWithLongNamesAreMovedAndDeleted(backend: IntegrationBackend) async throws {
			try await withIntegrationFixture(backend) { context in
				let sandbox = try await context.makeSandbox()
				let folderPath = sandbox.appendingPathComponent(String(repeating: "d", count: 200))
				let filePath = sandbox.appendingPathComponent(String(repeating: "f", count: 200))
				let renamedFilePath = sandbox.appendingPathComponent(String(repeating: "r", count: 200))
				let shortFilePath = sandbox.appendingPathComponent("shortName")
				let nestedFilePath = folderPath.appendingPathComponent("fileInFolderWithLongName")
				let localURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
				try Conformance.testContentForSandboxItems.write(to: localURL, atomically: true, encoding: .utf8)
				let (writer, writerRecorder) = try context.makeRecordingProvider()
				try await writer.createFolder(at: folderPath)
				_ = try await writer.uploadFile(from: localURL, to: filePath, replaceExisting: false)
				try await Conformance.waitUntilCreatedItemsAreVisible(of: writerRecorder, in: context)

				try await writer.moveFile(from: filePath, to: renamedFilePath)
				try await Conformance.waitUntilCreatedItemsAreVisible(of: writerRecorder, in: context)
				// Listed before the move to the short name, which deletes the `.c9s` directory of vault format 8 and its name file with it.
				let listingAfterRename = try await Conformance.coldListing(of: sandbox, expecting: [folderPath, renamedFilePath], in: context)

				try await writer.moveFile(from: renamedFilePath, to: shortFilePath)
				try await Conformance.waitUntilCreatedItemsAreVisible(of: writerRecorder, in: context)
				let shortTargetPath = writerRecorder.paths(of: .moveFile).last
				let listingAfterShortening = try await Conformance.coldListing(of: sandbox, expecting: [folderPath, shortFilePath], in: context)

				_ = try await writer.uploadFile(from: localURL, to: nestedFilePath, replaceExisting: false)
				try await Conformance.waitUntilCreatedItemsAreVisible(of: writerRecorder, in: context)
				let listingOfFolder = try await Conformance.coldListing(of: folderPath, expecting: [nestedFilePath], in: context)

				try await writer.deleteFile(at: shortFilePath)
				try await writer.deleteFile(at: nestedFilePath)
				try await writer.deleteFolder(at: folderPath)
				let listingAfterDeletion = try await Conformance.coldListing(of: sandbox, expecting: [], in: context)

				#expect(listingAfterRename.cloudPaths == [folderPath, renamedFilePath])
				#expect(shortTargetPath.map { Conformance.shortenedName(in: $0, of: backend.format) == nil } == true, "The file wasn't moved to an unshortened name")
				#expect(listingAfterShortening.cloudPaths == [folderPath, shortFilePath])
				#expect(listingOfFolder.cloudPaths == [nestedFilePath])
				#expect(listingAfterDeletion.cloudPaths == [])
			}
		}

		// MARK: - Helpers

		private static let testContentForSandboxItems = "AAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBABABABABABBABABABBABABABABABAB"

		private static func expectedRootFolderItems(in context: IntegrationTestContext) -> [CloudItemMetadata] {
			let cloudPath = context.treeRoot
			return (0 ..< 5).map { CloudItemMetadata(name: "test \($0).txt", cloudPath: cloudPath.appendingPathComponent("test \($0).txt"), itemType: .file, lastModifiedDate: nil, size: nil) }
				+ [CloudItemMetadata(name: "testFolder", cloudPath: cloudPath.appendingPathComponent("testFolder"), itemType: .folder, lastModifiedDate: nil, size: nil)]
		}

		private static func expectedTestFolderItems(in context: IntegrationTestContext) -> [CloudItemMetadata] {
			let cloudPath = context.treeRoot.appendingPathComponent("testFolder")
			return [CloudItemMetadata(name: "EmptySubfolder", cloudPath: cloudPath.appendingPathComponent("EmptySubfolder"), itemType: .folder, lastModifiedDate: nil, size: nil)]
				+ (0 ..< 5).map { CloudItemMetadata(name: "test \($0).txt", cloudPath: cloudPath.appendingPathComponent("test \($0).txt"), itemType: .file, lastModifiedDate: nil, size: nil) }
		}

		private static func remainingItemLists(after itemList: CloudItemList, forFolderAt cloudPath: CloudPath, through provider: CloudProvider) async throws -> [CloudItemList] {
			var itemLists = [CloudItemList]()
			var pageToken = itemList.nextPageToken
			while pageToken != nil {
				let nextItemList = try await provider.fetchItemList(forFolderAt: cloudPath, withPageToken: pageToken)
				itemLists.append(nextItemList)
				pageToken = nextItemList.nextPageToken
			}
			return itemLists
		}

		/**
		 Lists the folder with a new provider until it lists the expected paths, which must be sorted.

		 A listing that doesn't match yet is retried. A moved `.c9s` directory holds the name file of its old name until the new one is uploaded, so its item is left out until then. An eventually consistent provider can list an item before its name file or before the contents of its `.c9s` directory, which fails the listing as not found.
		 */
		private static func coldListing(of cloudPath: CloudPath, expecting expectedCloudPaths: [CloudPath], in context: IntegrationTestContext) async throws -> ColdListing {
			let (provider, recorder) = try context.makeRecordingProvider()
			var cloudPaths: [CloudPath]?
			_ = try await eventually(on: context.backend.kind) {
				do {
					cloudPaths = try await provider.fetchItemListExhaustively(forFolderAt: cloudPath).items.sorted().map(\.cloudPath)
				} catch CloudProviderError.itemNotFound, VaultFormat7ShorteningError.c9sItemNotFound {
					cloudPaths = nil
				}
				return cloudPaths == expectedCloudPaths
			}
			return ColdListing(cloudPaths: cloudPaths, provider: provider, recorder: recorder)
		}

		/// Waits until the account's provider sees every item that the recorder's calls created since the last wait, so that the next step doesn't fail on the visibility lag.
		private static func waitUntilCreatedItemsAreVisible(of recorder: PathRecordingProvider, in context: IntegrationTestContext) async throws {
			for cloudPath in recorder.takeCreatedPaths() {
				try await waitUntilVisible(cloudPath, through: context.rawProvider, on: context.backend.kind)
			}
		}

		/// The shortened name in the ciphertext path of an item or of a file in its `.c9s` directory, or `nil` if the path has none or is a name file's.
		private static func shortenedName(in cloudPath: CloudPath, of format: IntegrationVaultFormat) -> String? {
			guard shortenedName(ofNameFileAt: cloudPath, of: format) == nil else {
				return nil
			}
			let suffix = format == .vf6 ? ".lng" : ".c9s"
			return cloudPath.pathComponents.first { $0.hasSuffix(suffix) }
		}

		/// The shortened name whose name file is at the ciphertext path: below `m` in vault format 6, else the `name.c9s` of a `.c9s` directory.
		private static func shortenedName(ofNameFileAt cloudPath: CloudPath, of format: IntegrationVaultFormat) -> String? {
			if format == .vf6 {
				return cloudPath.pathComponents.contains("m") ? cloudPath.lastPathComponent : nil
			} else {
				return cloudPath.lastPathComponent == "name.c9s" ? cloudPath.deletingLastPathComponent().lastPathComponent : nil
			}
		}

		private static func expectDownload(from cloudPath: CloudPath, toHave expectedFileContent: String, in context: IntegrationTestContext) async throws {
			let localURL = context.tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let progress = Progress(totalUnitCount: 1)
			let metadata = try await context.provider.downloadFile(from: cloudPath, to: localURL, progress: progress, onTaskCreation: nil)
			let expectedLastModifiedDate = try await context.provider.fetchItemMetadata(at: cloudPath).lastModifiedDate
			#expect(try String(contentsOf: localURL, encoding: .utf8) == expectedFileContent)
			#expect(progress.fractionCompleted == 1.0)
			try expectMetadata(metadata, ofFile: localURL, at: cloudPath)
			#expect(metadata.lastModifiedDate.map { floor($0.timeIntervalSince1970) } == expectedLastModifiedDate.map { floor($0.timeIntervalSince1970) })
		}

		private static func expectMetadata(_ metadata: CloudItemMetadata, ofFile localURL: URL, at cloudPath: CloudPath) throws {
			let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
			#expect(metadata.cloudPath == cloudPath)
			#expect(metadata.name == cloudPath.lastPathComponent)
			#expect(metadata.size != nil)
			#expect(metadata.size == attributes[FileAttributeKey.size] as? Int)
			#expect(metadata.itemType == .file)
		}

		private static func expectMove(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath, in context: IntegrationTestContext) async throws {
			let provider = context.provider
			let sourceIsGone = try await eventually(on: context.backend.kind) { try await !provider.checkForItemExistence(at: sourceCloudPath) }
			let targetExists = try await eventually(on: context.backend.kind) { try await provider.checkForItemExistence(at: targetCloudPath) }
			#expect(sourceIsGone, "The source still exists")
			#expect(targetExists, "The target doesn't exist")
		}
	}
}

private struct ColdListing {
	/// The paths of the last listing, sorted by name, or `nil` if it failed because an item wasn't found.
	let cloudPaths: [CloudPath]?
	let provider: CloudProvider
	let recorder: PathRecordingProvider
}
