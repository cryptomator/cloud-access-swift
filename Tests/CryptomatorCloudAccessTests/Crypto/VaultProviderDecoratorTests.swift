//
//  VaultProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

/// The vault formats whose crypto decorators share a test, with the paths of their ciphertext items in the vault mock.
enum VaultTestFormat: CaseIterable, CustomTestStringConvertible {
	case vf6
	case vf7

	var testDescription: String {
		return "\(self)"
	}

	var fileNameEncoding: FileNameEncoding {
		switch self {
		case .vf6:
			return .base32
		case .vf7:
			return .base64url
		}
	}

	/// The delegate call that moves a folder's reference, which is a file in vault format 6 and a folder in vault format 7.
	var referenceMoveCall: String {
		switch self {
		case .vf6:
			return "moveFile"
		case .vf7:
			return "moveFolder"
		}
	}

	/// The delegate call that deletes a folder's reference.
	var referenceDeleteCall: String {
		switch self {
		case .vf6:
			return "deleteFile"
		case .vf7:
			return "deleteFolder"
		}
	}

	func makeCryptor() -> CryptorMock {
		switch self {
		case .vf6:
			return CryptorMock.vaultFormat6()
		case .vf7:
			return CryptorMock.vaultFormat7()
		}
	}

	/// Returns a fixture of the format's decorator, stacked onto a fresh vault mock as `stacking` says.
	func makeFixture(stacking: Stacking) throws -> VaultTestFixture {
		switch self {
		case .vf6:
			let cryptor = CryptorMock.vaultFormat6()
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: Self.vaultPath, cryptor: cryptor)
			return VaultTestFixture(provider: fixture.provider, cryptor: cryptor, decorator: fixture.decorator, dirIdCache: fixture.decorator.dirIdCache, tmpDirURL: fixture.decorator.tmpDirURL, shorteningTmpDirURL: fixture.shorteningDecorator?.tmpDirURL)
		case .vf7:
			let cryptor = CryptorMock.vaultFormat7()
			let fixture = try VaultFormat7Fixture(stacking: stacking, vaultPath: Self.vaultPath, cryptor: cryptor)
			return VaultTestFixture(provider: fixture.provider, cryptor: cryptor, decorator: fixture.decorator, dirIdCache: fixture.decorator.dirIdCache, tmpDirURL: fixture.decorator.tmpDirURL, shorteningTmpDirURL: fixture.shorteningDecorator?.tmpDirURL)
		}
	}

	/// Returns the format's decorator, stacked onto the provider directly.
	func makeDecorator(provider: CloudProvider, cryptor: VaultCryptor) throws -> any CloudProvider {
		switch self {
		case .vf6:
			return try VaultFormat6ProviderDecorator(provider: provider, vaultPath: Self.vaultPath, cryptor: cryptor)
		case .vf7:
			return try VaultFormat7ProviderDecorator(provider: provider, vaultPath: Self.vaultPath, cryptor: cryptor)
		}
	}

	func temporaryDirectoryURL(of decorator: any CloudProvider) throws -> URL {
		switch self {
		case .vf6:
			return try #require(decorator as? VaultFormat6ProviderDecorator).tmpDirURL
		case .vf7:
			return try #require(decorator as? VaultFormat7ProviderDecorator).tmpDirURL
		}
	}

	/// Returns a provider that holds the given folder references and, unless one replaces it, that of `Directory 1`. A key is the path of the directory and the encrypted folder name (e.g. `pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2`), a value the dir ID. The directories of the root and of `dir1-id` to `dir4-id` exist. A download of a file at a path of `aliasedDownloads` reports an alias.
	func makeNestedProvider(references: [String: String], aliasedDownloads: Set<String> = []) -> CloudProviderMock {
		let references = ["\(VaultTestFormat.rootDirectory)/dir1": "dir1-id"].merging(references) { $1 }
		let referenceLocations = references.keys.map { CloudPath($0) }.map { (name: $0.lastPathComponent, directory: $0.deletingLastPathComponent().path) }
		let referenceFolders = self == .vf7 ? referenceLocations.map { referencePath($0.name, in: $0.directory) } : []
		let folders = Set(["pathToVault", "pathToVault/d"] + Self.nestedDirectories.map { "pathToVault/d/\($0)" } + referenceFolders)
		let dirFiles = Dictionary(uniqueKeysWithValues: zip(referenceLocations, references.values).map { location, dirId in
			(dirFilePath(location.name, in: location.directory), Data(dirId.utf8))
		})
		return CloudProviderMock(folders: folders, files: dirFiles, aliasedDownloads: aliasedDownloads)
	}

	/// The path of the ciphertext file of the given encrypted name in the given directory.
	func filePath(_ name: String, in directory: String) -> String {
		switch self {
		case .vf6:
			return "\(directory)/\(name)"
		case .vf7:
			return "\(directory)/\(name).c9r"
		}
	}

	/// The path of the item that refers to the directory of the folder of the given encrypted name in the given directory.
	func referencePath(_ name: String, in directory: String) -> String {
		switch self {
		case .vf6:
			return "\(directory)/0\(name)"
		case .vf7:
			return "\(directory)/\(name).c9r"
		}
	}

	/// The path of the file that holds the dir ID of the folder of the given encrypted name in the given directory.
	func dirFilePath(_ name: String, in directory: String) -> String {
		switch self {
		case .vf6:
			return referencePath(name, in: directory)
		case .vf7:
			return "\(referencePath(name, in: directory))/dir.c9r"
		}
	}
}

/// A crypto decorator of a test's format, stacked onto a fresh vault mock.
struct VaultTestFixture {
	let provider: CloudProviderMock
	let cryptor: CryptorMock
	let decorator: any CloudProvider
	let dirIdCache: DirectoryIdCache
	let tmpDirURL: URL
	let shorteningTmpDirURL: URL?
}

/// The requests that a vault mock received, with the paths that its hooks and records hold.
struct RecordedRequests: Equatable {
	var calls: [String] = []
	var metadataReads: [String] = []
	var listings: [String] = []
	var transfers: [String] = []
	var createdFolders: [String] = []
	var createdFiles: [String] = []
	var deleted: [String] = []
	var moved: [String: String] = [:]
}

extension CloudProviderMock {
	/// Replaces `metadataHook`, `listingHook` and `transferHook` with hooks that record the requested paths, and returns a closure that reads every request so far.
	func recordingRequests() -> @Sendable () -> RecordedRequests {
		let paths = OSAllocatedUnfairLock(initialState: (metadataReads: [String](), listings: [String](), transfers: [String]()))
		metadataHook = { cloudPath in
			paths.withLock { $0.metadataReads.append(cloudPath.path) }
		}
		listingHook = { cloudPath, _ in
			paths.withLock { $0.listings.append(cloudPath.path) }
		}
		transferHook = { cloudPath, _ in
			paths.withLock { $0.transfers.append(cloudPath.path) }
		}
		return { [self] in
			let recordedPaths = paths.withLock { $0 }
			return RecordedRequests(calls: calls, metadataReads: recordedPaths.metadataReads, listings: recordedPaths.listings, transfers: recordedPaths.transfers, createdFolders: createdFolders, createdFiles: createdFiles.keys.sorted(), deleted: deleted, moved: moved)
		}
	}
}

/// An operation whose ciphertext path a decorator derives after reading the dir ID of the parent folder.
enum PathDerivingOperation: CaseIterable, CustomTestStringConvertible {
	case fetchItemMetadata
	case downloadFile
	case uploadFile

	var testDescription: String {
		return "\(self)"
	}

	func run(on provider: CloudProvider, at cloudPath: CloudPath, localDirectoryURL: URL) async throws {
		let localURL = localDirectoryURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
		switch self {
		case .fetchItemMetadata:
			_ = try await provider.fetchItemMetadata(at: cloudPath)
		case .downloadFile:
			_ = try await provider.downloadFile(from: cloudPath, to: localURL)
		case .uploadFile:
			try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
			_ = try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false)
		}
	}
}

/// An operation that takes the given path as its source or target, with a valid path in any other role.
enum PathCheckingOperation: CaseIterable, CustomTestStringConvertible {
	case downloadFile
	case deleteFile
	case moveFileFrom
	case moveFolderFrom
	case uploadFile
	case createFolder
	case moveFileTo
	case moveFolderTo

	var testDescription: String {
		return "\(self)"
	}

	private var takesPathAsSource: Bool {
		switch self {
		case .downloadFile, .deleteFile, .moveFileFrom, .moveFolderFrom:
			return true
		case .uploadFile, .createFolder, .moveFileTo, .moveFolderTo:
			return false
		}
	}

	var rootError: CloudProviderError {
		return takesPathAsSource ? .itemTypeMismatch : .itemAlreadyExists
	}

	var missingParentError: CloudProviderError {
		return takesPathAsSource ? .itemNotFound : .parentFolderDoesNotExist
	}

	func run(on provider: CloudProvider, at cloudPath: CloudPath, localDirectoryURL: URL) async throws {
		let localURL = localDirectoryURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
		switch self {
		case .downloadFile:
			_ = try await provider.downloadFile(from: cloudPath, to: localURL)
		case .deleteFile:
			try await provider.deleteFile(at: cloudPath)
		case .moveFileFrom:
			try await provider.moveFile(from: cloudPath, to: CloudPath("/File 3"))
		case .moveFolderFrom:
			try await provider.moveFolder(from: cloudPath, to: CloudPath("/Directory 2"))
		case .uploadFile:
			try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
			_ = try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: true)
		case .createFolder:
			try await provider.createFolder(at: cloudPath)
		case .moveFileTo:
			try await provider.moveFile(from: CloudPath("/File 1"), to: cloudPath)
		case .moveFolderTo:
			try await provider.moveFolder(from: CloudPath("/Directory 1"), to: cloudPath)
		}
	}
}

extension UnitTests {
	final class VaultProviderDecoratorTests {
		let tmpDirURL: URL

		init() throws {
			self.tmpDirURL = try makeTemporaryDirectory()
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func temporaryDirectoryLiesInProcessFolder(format: VaultTestFormat, stacking: Stacking) throws {
			let fixture = try format.makeFixture(stacking: stacking)
			#expect(try ProcessTemporaryDirectory.shared.directoryURL().path == fixture.tmpDirURL.deletingLastPathComponent().path)
			#expect((fixture.shorteningTmpDirURL != nil) == (stacking == .shortening))
			if let shorteningTmpDirURL = fixture.shorteningTmpDirURL {
				#expect(try ProcessTemporaryDirectory.shared.directoryURL().path == shorteningTmpDirURL.deletingLastPathComponent().path)
			}
		}

		// MARK: - Metadata and Listing

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func testFetchItemMetadata(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let metadata = try await fixture.decorator.fetchItemMetadata(at: CloudPath("/Directory 1/File 3"))
			#expect(metadata.name == "File 3")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/Directory 1/File 3")
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func fetchItemMetadataOfRootReadsItsDirectory(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			let metadata = try await fixture.decorator.fetchItemMetadata(at: .root)
			#expect(metadata == CloudItemMetadata(name: "/", cloudPath: .root, itemType: .folder, lastModifiedDate: fixture.provider.lastModifiedDate, size: nil))
			#expect(requests() == RecordedRequests(calls: ["fetchItemMetadata"], metadataReads: [VaultTestFormat.rootDirectory]))
		}

		@Test(arguments: VaultTestFormat.allCases)
		func fetchItemMetadataOfRootWithoutFolderAtItsDirectoryThrows(format: VaultTestFormat) async throws {
			let fileProvider = CloudProviderMock(folders: [], files: [VaultTestFormat.rootDirectory: Data()])
			let fileDecorator = try format.makeDecorator(provider: fileProvider, cryptor: format.makeCryptor())
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await fileDecorator.fetchItemMetadata(at: .root) }
			let emptyProvider = CloudProviderMock(folders: [VaultTestFormat.vaultPath.path], files: [:])
			let emptyDecorator = try format.makeDecorator(provider: emptyProvider, cryptor: format.makeCryptor())
			await #expect(throws: CloudProviderError.itemNotFound) { try await emptyDecorator.fetchItemMetadata(at: .root) }
		}

		/// Only the shortening decorator restores the long names.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func fetchItemListForRootDir(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let itemList = try await fixture.decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			switch stacking {
			case .plain:
				#expect(itemList.items.map(\.name).sorted() == ["Directory 1", "File 1", "File 2"])
			case .shortening:
				#expect(itemList.items.map(\.name).sorted() == ["Directory 1", "Directory 3 (Long)", "File 1", "File 2", "File 4 (Long)", "File 5 (Long)"])
			}
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func fetchItemListForSubDir(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let itemList = try await fixture.decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1"), withPageToken: nil)
			#expect(itemList.items.map(\.name).sorted() == ["Directory 2", "File 3"])
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func fetchItemListForEmptyDir(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let itemList = try await fixture.decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1/Directory 2"), withPageToken: nil)
			#expect(itemList.items.isEmpty)
		}

		@Test(arguments: VaultTestFormat.allCases)
		func fetchItemListSkipsNamesThatAreNoSinglePathComponent(format: VaultTestFormat) async throws {
			let dirPath = VaultTestFormat.rootDirectory
			let files = Dictionary(uniqueKeysWithValues: ["nested", "parent", "file1"].map { (format.filePath($0, in: dirPath), Data()) })
			let provider = CloudProviderMock(folders: VaultTestFormat.rootDirectoryAncestors.union([dirPath]), files: files)
			let cryptor = CryptorMock(dirIds: ["": VaultTestFormat.encryptedRootDirId], fileNames: ["nested": "a/b", "parent": "..", "file1": "File 1"], contents: [:])
			let decorator = try format.makeDecorator(provider: provider, cryptor: cryptor)
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect([CloudPath("/File 1")] == itemList.items.map(\.cloudPath))
		}

		@Test(arguments: VaultTestFormat.allCases)
		func fetchItemListWithTooLargeDirFileThrowsInvalidDirectoryReference(format: VaultTestFormat) async throws {
			let provider = format.makeNestedProvider(references: ["\(VaultTestFormat.rootDirectory)/dir1": String(repeating: "a", count: vaultDirFileMaxLength + 1)])
			let decorator = try format.makeDecorator(provider: provider, cryptor: format.makeCryptor())
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1"), withPageToken: nil) }
		}

		/// Only a delete refuses a dir file read through an alias, because a vault reached through a shortcut stays usable.
		@Test(arguments: VaultTestFormat.allCases)
		func fetchItemListBelowDirFileDownloadedThroughAlias(format: VaultTestFormat) async throws {
			let provider = format.makeNestedProvider(references: [:], aliasedDownloads: [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory)])
			let (listedFolders, _) = provider.recordingListingsAndTransfers()
			let decorator = try format.makeDecorator(provider: provider, cryptor: format.makeCryptor())
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1"), withPageToken: nil)
			#expect(itemList.items.isEmpty)
			#expect(listedFolders.withLock { $0 } == [VaultTestFormat.directory1])
		}

		// MARK: - Download

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func testDownloadFile(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
			let progress = Progress(totalUnitCount: 1)
			let transfer = SuspendedTransfer()
			fixture.provider.transferHook = transfer.run
			let download = Task {
				try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL, progress: progress, onTaskCreation: nil)
			}
			await transfer.suspended.wait()
			#expect(progress.fractionCompleted > 0)
			#expect(progress.fractionCompleted < 1)
			transfer.resume()
			let metadata = try await cancellingValue(of: download)
			#expect(progress.fractionCompleted == 1)
			#expect(try String(contentsOf: localURL, encoding: .utf8) == "cleartext1")
			#expect(metadata.name == "File 1")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/File 1")
			#expect(fixture.provider.lastModifiedDate == metadata.lastModifiedDate)
			#expect(metadata.size == 10)
			#expect(try FileManager.default.contentsOfDirectory(atPath: fixture.tmpDirURL.path) == [])
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func downloadFileWithFailingTransfer(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
			let progress = Progress(totalUnitCount: 1)
			let transfer = SuspendedTransfer()
			fixture.provider.transferHook = transfer.run
			let download = Task {
				try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL, progress: progress, onTaskCreation: nil)
			}
			await transfer.suspended.wait()
			transfer.resume(with: .failure(CloudProviderError.noInternetConnection))
			await #expect(throws: CloudProviderError.noInternetConnection) { try await cancellingValue(of: download) }
			#expect(progress.fractionCompleted < 1)
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func downloadFileWithFailingCleartextMetadata(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let localURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
			let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
			fixture.cryptor.decryptContentHook = { ciphertextURL, cleartextURL in
				temporaryURLs.withLock { $0 = [ciphertextURL, cleartextURL] }
			}
			fixture.cryptor.decryptFileNameError = CryptorMockError.notMocked
			await #expect(throws: CryptorMockError.notMocked) { try await fixture.decorator.downloadFile(from: CloudPath("/File 1"), to: localURL) }
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
			assertDeleted(temporaryURLs.withLock { $0 })
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func downloadFileWithCancellationBeforePublication(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
			let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
			fixture.cryptor.decryptContentHook = { ciphertextURL, cleartextURL in
				temporaryURLs.withLock { $0 = [ciphertextURL, cleartextURL] }
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let download = Task {
				try await decorator.downloadFile(from: CloudPath("/File 1"), to: localURL)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
			assertDeleted(temporaryURLs.withLock { $0 })
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func downloadFileWithDestinationCreatedDuringDownload(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let localURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
			let progress = Progress(totalUnitCount: 1)
			let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
			fixture.cryptor.decryptContentHook = { ciphertextURL, cleartextURL in
				temporaryURLs.withLock { $0 = [ciphertextURL, cleartextURL] }
				try "other".write(to: localURL, atomically: true, encoding: .utf8)
			}
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await fixture.decorator.downloadFile(from: CloudPath("/File 1"), to: localURL, progress: progress, onTaskCreation: nil) }
			#expect(try String(contentsOf: localURL, encoding: .utf8) == "other")
			#expect(progress.fractionCompleted < 1)
			assertDeleted(temporaryURLs.withLock { $0 })
		}

		@Test(arguments: VaultTestFormat.allCases)
		func downloadFileWithCancellationDuringDecryption(format: VaultTestFormat) async throws {
			let cryptor = try Cryptor(masterkey: Masterkey.createNew(), scheme: .sivCtrMac)
			let cloudPath = CloudPath("/File")
			let cleartextURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
			try Data(count: 1024 * 1024).write(to: cleartextURL)
			let rootDirId = try cryptor.encryptDirId(Data())
			let provider = CloudProviderMock(folders: ["pathToVault/d/\(rootDirId.prefix(2))/\(rootDirId.dropFirst(2))"], files: [:])
			let decorator = try format.makeDecorator(provider: provider, cryptor: cryptor)
			_ = try await decorator.uploadFile(from: cleartextURL, to: cloudPath, replaceExisting: false)
			let localURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
			let progress = Progress(totalUnitCount: 1)
			// The transfer makes up the first 79.9 % of the progress, the decryption the following 20 %.
			let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
				if progress.fractionCompleted > 0.8 {
					withUnsafeCurrentTask { $0?.cancel() }
				}
			}
			let download = Task {
				try await decorator.downloadFile(from: cloudPath, to: localURL, progress: progress, onTaskCreation: nil)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }
			progressObserver.invalidate()
			#expect(progress.fractionCompleted < 0.9, "The decryption must not have finished")
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
			#expect(try FileManager.default.contentsOfDirectory(atPath: format.temporaryDirectoryURL(of: decorator).path) == [])
		}

		// MARK: - Upload

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func testUploadFile(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let decorator = fixture.decorator
			let localURL = try makeLocalFile(in: tmpDirURL, content: "cleartext1")
			let progress = Progress(totalUnitCount: 1)
			let transfer = SuspendedTransfer()
			fixture.provider.transferHook = transfer.run
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File 3"), replaceExisting: false, progress: progress, onTaskCreation: nil)
			}
			await transfer.suspended.wait()
			#expect(progress.fractionCompleted > 0)
			#expect(progress.fractionCompleted < 1)
			transfer.resume()
			let metadata = try await cancellingValue(of: upload)
			#expect(progress.fractionCompleted == 1)
			#expect(fixture.provider.createdFiles == [format.filePath("file3", in: VaultTestFormat.rootDirectory): Data("ciphertext1".utf8)])
			#expect(metadata.name == "File 3")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/File 3")
			#expect(try FileManager.default.contentsOfDirectory(atPath: fixture.tmpDirURL.path) == [])
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func uploadFileWithFailingTransfer(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let decorator = fixture.decorator
			let localURL = try makeLocalFile(in: tmpDirURL, content: "cleartext1")
			let progress = Progress(totalUnitCount: 1)
			let transfer = SuspendedTransfer()
			fixture.provider.transferHook = transfer.run
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File 3"), replaceExisting: false, progress: progress, onTaskCreation: nil)
			}
			await transfer.suspended.wait()
			transfer.resume(with: .failure(CloudProviderError.quotaInsufficient))
			await #expect(throws: CloudProviderError.quotaInsufficient) { try await cancellingValue(of: upload) }
			#expect(progress.fractionCompleted < 1)
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func uploadFileWithCancellationAfterEncryption(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let decorator = fixture.decorator
			let localURL = try makeLocalFile(in: tmpDirURL, content: "cleartext1")
			let temporaryURLs = OSAllocatedUnfairLock(initialState: [URL]())
			fixture.cryptor.encryptContentHook = { _, ciphertextURL in
				temporaryURLs.withLock { $0 = [ciphertextURL] }
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File 1"), replaceExisting: false)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }
			#expect(!fixture.provider.calls.contains("uploadFile"))
			assertDeleted(temporaryURLs.withLock { $0 })
		}

		@Test(arguments: VaultTestFormat.allCases)
		func uploadFileWithCancellationDuringEncryption(format: VaultTestFormat) async throws {
			let provider = CloudProviderMock(folders: [], files: [:])
			let decorator = try format.makeDecorator(provider: provider, cryptor: Cryptor(masterkey: Masterkey.createNew(), scheme: .sivCtrMac))
			let localURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
			try Data(count: 1024 * 1024).write(to: localURL)
			let progress = Progress(totalUnitCount: 1)
			let progressObserver = progress.observe(\.fractionCompleted) { progress, _ in
				if progress.fractionCompleted > 0 {
					withUnsafeCurrentTask { $0?.cancel() }
				}
			}
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File"), replaceExisting: false, progress: progress, onTaskCreation: nil)
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }
			progressObserver.invalidate()
			// The encryption makes up the first 20 % of the progress.
			#expect(progress.fractionCompleted < 0.2, "The encryption must not have finished")
			#expect(!provider.calls.contains("uploadFile"))
			#expect(try FileManager.default.contentsOfDirectory(atPath: format.temporaryDirectoryURL(of: decorator).path) == [])
		}

		/// cryptolib sizes the encryption progress from the attributes of the URL it gets, which don't follow a symbolic link.
		@Test(arguments: VaultTestFormat.allCases)
		func uploadFileThroughSymbolicLinkEncryptsTarget(format: VaultTestFormat) async throws {
			let fixture = try format.makeFixture(stacking: .plain)
			let targetURL = try makeLocalFile(in: tmpDirURL, named: "target", content: "cleartext1")
			let linkURL = tmpDirURL.appending(component: "link", directoryHint: .notDirectory)
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
			let encryptedURLs = OSAllocatedUnfairLock(initialState: [URL]())
			fixture.cryptor.encryptContentHook = { cleartextURL, _ in
				encryptedURLs.withLock { $0.append(cleartextURL) }
			}
			_ = try await fixture.decorator.uploadFile(from: linkURL, to: CloudPath("/File 3"), replaceExisting: false)
			#expect(encryptedURLs.withLock { $0 }.map(\.lastPathComponent) == ["target"])
		}

		@Test(arguments: VaultTestFormat.allCases, [false, true])
		func uploadFileFromUnusableSourceThrowsBeforeAnyRequest(format: VaultTestFormat, sourceIsFolder: Bool) async throws {
			let fixture = try format.makeFixture(stacking: .plain)
			let sourceURL = sourceIsFolder ? tmpDirURL : tmpDirURL.appending(component: "link", directoryHint: .notDirectory)
			if !sourceIsFolder {
				try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: tmpDirURL.appending(component: "missing", directoryHint: .notDirectory))
			}
			await #expect(throws: sourceIsFolder ? CloudProviderError.itemTypeMismatch : .itemNotFound) {
				try await fixture.decorator.uploadFile(from: sourceURL, to: CloudPath("/Directory 1/File"), replaceExisting: false)
			}
			#expect(fixture.provider.calls == [])
		}

		// MARK: - Folder Creation

		/// The task is cancelled while the dir ID of the parent is read.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func createFolderWithCancellationBeforeFirstRemoteChange(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let decorator = fixture.decorator
			fixture.provider.transferHook = { _, _ in
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let creation = Task {
				try await decorator.createFolder(at: CloudPath("/Directory 1/Directory 1"))
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: creation) }
			#expect(creation.isCancelled)
			#expect(fixture.provider.createdFolders.isEmpty)
			#expect(fixture.provider.createdFiles.isEmpty)
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func createFolderWithCancellationAfterFirstRemoteChange(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let decorator = fixture.decorator
			try await valueCancelledAfterFirstRemoteChange(of: fixture.provider) {
				try await decorator.createFolder(at: CloudPath("/Directory 2"))
			}
			let referenceFolders = format == .vf7 ? [format.referencePath("dir2", in: VaultTestFormat.rootDirectory)] : []
			#expect(fixture.provider.createdFolders.sorted() == (referenceFolders + [VaultTestFormat.newDirectoryParent, VaultTestFormat.newDirectory]).sorted())
			#expect(Array(fixture.provider.createdFiles.keys) == [format.dirFilePath("dir2", in: VaultTestFormat.rootDirectory)])
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 2")) != nil)
		}

		// MARK: - Deletion

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func deleteFolderWithoutSubDirs(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			try await fixture.decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2"))
			#expect(fixture.provider.deleted == [VaultTestFormat.directory2, format.referencePath("dir2", in: VaultTestFormat.directory1)])
		}

		@Test(arguments: VaultTestFormat.allCases)
		func deleteFolderWithPagedItemList(format: VaultTestFormat) async throws {
			let fixture = try format.makeFixture(stacking: .plain)
			let files = fixture.provider.files.merging([format.filePath("a", in: VaultTestFormat.directory1): Data()]) { $1 }
			let pagingProvider = CloudProviderMock(folders: fixture.provider.folders, files: files, maxPageSize: 1)
			let decorator = try format.makeDecorator(provider: pagingProvider, cryptor: fixture.cryptor)
			try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			#expect(pagingProvider.deleted.sorted() == [format.referencePath("dir1", in: VaultTestFormat.rootDirectory), VaultTestFormat.directory1, VaultTestFormat.directory2])
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func deleteFolderWithCancellationAfterFirstRemoteChange(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let decorator = fixture.decorator
			try await valueCancelledAfterFirstRemoteChange(of: fixture.provider) {
				try await decorator.deleteFolder(at: CloudPath("/Directory 1"))
			}
			#expect(fixture.provider.deleted.sorted() == [format.referencePath("dir1", in: VaultTestFormat.rootDirectory), VaultTestFormat.directory1, VaultTestFormat.directory2])
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func deleteFolderWithDeletionIncompleteKeepsReference(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			fixture.provider.mutationFailure = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: [VaultTestFormat.directory1])
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await fixture.decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(!fixture.provider.deleted.contains(format.referencePath("dir1", in: VaultTestFormat.rootDirectory)))
			#expect(try Data("dir1-id".utf8) == fixture.dirIdCache.get(CloudPath("/Directory 1")))
		}

		/// The folder's directory is deleted before its reference, and the provider may have deleted the reference although it threw, so the cache no longer maps the path.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func deleteFolderWithFailedReferenceDeleteDropsCachedDirId(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			fixture.provider.mutationFailure = CloudProviderMock.failing(format.referenceDeleteCall, with: URLError(.timedOut), at: [format.referencePath("dir1", in: VaultTestFormat.rootDirectory)])
			await #expect(throws: URLError(.timedOut)) { try await fixture.decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		/// On Google Drive, a shortcut can share a genuine dir file's name, and a read of that path can reach the shortcut's target. The walk refuses it, so the directory of `Directory 2` is neither listed nor deleted.
		@Test(arguments: VaultTestFormat.allCases)
		func deleteFolderKeepsFolderWhoseDirFileDownloadsThroughAlias(format: VaultTestFormat) async throws {
			let provider = format.makeNestedProvider(references: ["\(VaultTestFormat.directory1)/dir2": "dir2-id"], aliasedDownloads: [format.dirFilePath("dir2", in: VaultTestFormat.directory1)])
			let (listedFolders, _) = provider.recordingListingsAndTransfers()
			let decorator = try format.makeDecorator(provider: provider, cryptor: format.makeCryptor())
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			let listedReferenceFolders = format == .vf7 ? [format.referencePath("dir2", in: VaultTestFormat.directory1)] : []
			#expect(listedFolders.withLock { $0 } == [VaultTestFormat.directory1] + listedReferenceFolders)
			#expect(provider.deleted == [])
		}

		/// The read of the ancestor's dir ID refuses the alias before the folder's own dir file is read or anything is listed.
		@Test(arguments: VaultTestFormat.allCases)
		func deleteFolderWhoseAncestorDirFileDownloadsThroughAliasThrowsInvalidDirectoryReference(format: VaultTestFormat) async throws {
			let ancestorDirFilePath = format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory)
			let provider = format.makeNestedProvider(references: ["\(VaultTestFormat.directory1)/dir2": "dir2-id"], aliasedDownloads: [ancestorDirFilePath])
			let (listedFolders, transferredFiles) = provider.recordingListingsAndTransfers()
			let decorator = try format.makeDecorator(provider: provider, cryptor: format.makeCryptor())
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2")) }
			#expect(listedFolders.withLock { $0 } == [])
			#expect(transferredFiles.withLock { $0 } == [ancestorDirFilePath])
			#expect(provider.deleted == [])
		}

		/// The read of the folder's own dir ID refuses the alias before anything is listed.
		@Test(arguments: VaultTestFormat.allCases)
		func deleteFolderWhoseOwnDirFileDownloadsThroughAliasThrowsInvalidDirectoryReference(format: VaultTestFormat) async throws {
			let dirFilePath = format.dirFilePath("dir2", in: VaultTestFormat.directory1)
			let provider = format.makeNestedProvider(references: ["\(VaultTestFormat.directory1)/dir2": "dir2-id"], aliasedDownloads: [dirFilePath])
			let (listedFolders, transferredFiles) = provider.recordingListingsAndTransfers()
			let decorator = try format.makeDecorator(provider: provider, cryptor: format.makeCryptor())
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2")) }
			#expect(listedFolders.withLock { $0 } == [])
			#expect(transferredFiles.withLock { $0 } == [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory), dirFilePath])
			#expect(provider.deleted == [])
		}

		/// `Directory 5` inside `Directory 2` refers to the directory of `Directory 1`, which contains it, so the walk never lists that directory.
		@Test(arguments: VaultTestFormat.allCases)
		func deleteFolderWithDirFileNamingAncestorThrowsInvalidDirectoryReference(format: VaultTestFormat) async throws {
			let provider = format.makeNestedProvider(references: ["\(VaultTestFormat.directory1)/dir2": "dir2-id", "\(VaultTestFormat.directory2)/dir5": "dir1-id"])
			let listedFolders = OSAllocatedUnfairLock(initialState: [String]())
			provider.listingHook = CloudProviderMock.listingEachFolderOnce(recordingInto: listedFolders)
			let decorator = try format.makeDecorator(provider: provider, cryptor: format.makeCryptor())
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2")) }
			let listedReferenceFolders = format == .vf7 ? [format.referencePath("dir5", in: VaultTestFormat.directory2)] : []
			#expect(listedFolders.withLock { $0 } == [VaultTestFormat.directory2] + listedReferenceFolders)
			#expect(provider.deleted == [])
		}

		/// The dir file of `Directory 1` is empty, which is the dir ID of the root, so `Directory 2` would resolve to the root's `Directory 2`.
		@Test(arguments: VaultTestFormat.allCases)
		func deleteFolderBelowFolderWhoseDirFileNamesRootReadsNoFurtherDirFile(format: VaultTestFormat) async throws {
			let provider = format.makeNestedProvider(references: ["\(VaultTestFormat.rootDirectory)/dir1": "", "\(VaultTestFormat.rootDirectory)/dir2": "dir2-id"])
			let (listedFolders, transferredFiles) = provider.recordingListingsAndTransfers()
			let decorator = try format.makeDecorator(provider: provider, cryptor: format.makeCryptor())
			await #expect(throws: VaultFormatError.invalidDirectoryReference) { try await decorator.deleteFolder(at: CloudPath("/Directory 1/Directory 2")) }
			#expect(listedFolders.withLock { $0 } == [])
			#expect(transferredFiles.withLock { $0 } == [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory)])
			#expect(provider.deleted == [])
		}

		// MARK: - Moves

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func moveFolderWithMoveCompletedUpdatesCacheAndRethrows(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			try fixture.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir1-id".utf8))
			fixture.provider.mutationFailure = CloudProviderMock.failing(format.referenceMoveCall, with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await fixture.decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2")) }
			#expect(try Data("dir1-id".utf8) == fixture.dirIdCache.get(CloudPath("/Directory 2")))
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		/// The provider may have applied a move that threw an error other than `moveCompletedWithSourceRemaining`, so the cache maps neither path.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func moveFolderWithOtherMoveErrorDropsCachedDirIds(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			try fixture.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir1-id".utf8))
			try fixture.dirIdCache.addOrUpdate(CloudPath("/Directory 2"), dirId: Data("dir2-id".utf8))
			fixture.provider.mutationFailure = CloudProviderMock.failing(format.referenceMoveCall, with: URLError(.timedOut))
			await #expect(throws: URLError(.timedOut)) { try await fixture.decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2")) }
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 1")) == nil)
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 2")) == nil)
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func throwsCancellationErrorInCancelledTask(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			await assertThrowsCancellationErrorInCancelledTask(fixture.decorator)
			#expect(fixture.provider.calls == [])
		}

		// MARK: - Root and Unresolvable Paths

		@Test(arguments: VaultTestFormat.allCases, PathCheckingOperation.allCases)
		func operationAtRootThrowsWithoutRequest(format: VaultTestFormat, operation: PathCheckingOperation) async throws {
			let fixture = try format.makeFixture(stacking: .shortening)
			await #expect(throws: operation.rootError) {
				try await operation.run(on: fixture.decorator, at: .root, localDirectoryURL: tmpDirURL)
			}
			#expect(fixture.provider.calls == [])
		}

		@Test(arguments: VaultTestFormat.allCases)
		func unresolvablePathsThrowWithoutRequest(format: VaultTestFormat) async throws {
			let fixture = try format.makeFixture(stacking: .shortening)
			let localURL = try makeLocalFile(in: tmpDirURL)
			for testCase in try MutationGuardCases.makeInvalidPathCases(localURL: localURL, downloadURL: tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory), paths: MutationGuardCases.unresolvablePaths()) {
				await #expect(throws: testCase.expected, "\(testCase.name)") { try await testCase.operation(fixture.decorator) }
			}
			#expect(fixture.provider.calls == [])
		}

		@Test(arguments: VaultTestFormat.allCases)
		func moveOfRootOntoRootThrowsItemTypeMismatch(format: VaultTestFormat) async throws {
			let fixture = try format.makeFixture(stacking: .shortening)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await fixture.decorator.moveFile(from: .root, to: .root) }
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await fixture.decorator.moveFolder(from: .root, to: .root) }
			#expect(fixture.provider.calls == [])
		}

		@Test(arguments: VaultTestFormat.allCases)
		func deleteFolderAtRootThrowsItemTypeMismatchWithoutRequest(format: VaultTestFormat) async throws {
			let fixture = try format.makeFixture(stacking: .shortening)
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await fixture.decorator.deleteFolder(at: .root) }
			#expect(fixture.provider.calls == [])
		}

		/// `deleteFolderIfExisting` would report `itemNotFound` as success, although the folder that the path spells may exist.
		@Test(arguments: VaultTestFormat.allCases)
		func deleteFolderIfExistingAtUnresolvablePathThrowsWithoutRequest(format: VaultTestFormat) async throws {
			let fixture = try format.makeFixture(stacking: .shortening)
			for cloudPath in try VaultProviderDecoratorTests.unresolvablePaths() {
				await #expect(throws: CloudProviderError.invalidPath, "\(cloudPath.path)") { try await fixture.decorator.deleteFolderIfExisting(at: cloudPath) }
			}
			#expect(fixture.provider.calls == [])
		}

		/// `init(_:)` removes a `..` that follows a named component, so only a decoded path can keep one.
		private static func unresolvablePaths() throws -> [CloudPath] {
			let decodedPath = try JSONDecoder().decode(CloudPath.self, from: Data(#"{"path":"/Directory 1/../File 1"}"#.utf8))
			return [CloudPath("/.."), CloudPath("Directory 1/File 3"), decodedPath]
		}

		// MARK: - Missing Parent Folders

		@Test(arguments: VaultTestFormat.allCases, PathCheckingOperation.allCases)
		func operationBelowMissingFolderThrows(format: VaultTestFormat, operation: PathCheckingOperation) async throws {
			for stacking in Stacking.allCases {
				let fixture = try format.makeFixture(stacking: stacking)
				await #expect(throws: operation.missingParentError, "\(stacking)") {
					try await operation.run(on: fixture.decorator, at: CloudPath("/Directory 2/File 1"), localDirectoryURL: tmpDirURL)
				}
			}
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func readsAndDeletesBelowMissingFolderReportAbsence(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			await #expect(throws: CloudProviderError.itemNotFound) { try await fixture.decorator.fetchItemMetadata(at: CloudPath("/Directory 2/File 1")) }
			await #expect(throws: CloudProviderError.itemNotFound) { try await fixture.decorator.deleteFolder(at: CloudPath("/Directory 2/Directory 1")) }
			try await fixture.decorator.deleteFolderIfExisting(at: CloudPath("/Directory 2/Directory 1"))
			#expect(fixture.provider.deleted == [])
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func moveFromMissingFolderIntoMissingFolderThrowsParentFolderDoesNotExist(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await fixture.decorator.moveFile(from: CloudPath("/Directory 2/File 1"), to: CloudPath("/File 3/File 1")) }
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await fixture.decorator.moveFolder(from: CloudPath("/Directory 2/Directory 1"), to: CloudPath("/File 3/Directory 1")) }
			#expect(fixture.provider.moved == [:])
		}

		// MARK: - Parent Files

		/// The calls that change a vault mock's items.
		private static let mutationCalls: Set = ["uploadFile", "createFolder", "moveFile", "moveFolder", "deleteFile", "deleteFolder"]

		/// The paths below a file of the vault mocks that the stacking can address. `File 4 (Long)` exists only in shortened form, so only the shortening stacking reaches it.
		private static func pathsBelowFile(for stacking: Stacking) -> [CloudPath] {
			return [CloudPath("/File 1/File 3")] + (stacking == .shortening ? [CloudPath("/File 4 (Long)/File 3")] : [])
		}

		@Test(arguments: VaultTestFormat.allCases, PathCheckingOperation.allCases)
		func operationBelowFileThrows(format: VaultTestFormat, operation: PathCheckingOperation) async throws {
			for stacking in Stacking.allCases {
				for cloudPath in Self.pathsBelowFile(for: stacking) {
					let fixture = try format.makeFixture(stacking: stacking)
					await #expect(throws: operation.missingParentError, "\(stacking) \(cloudPath.path)") {
						try await operation.run(on: fixture.decorator, at: cloudPath, localDirectoryURL: tmpDirURL)
					}
					#expect(Self.mutationCalls.isDisjoint(with: fixture.provider.calls), "\(stacking) \(cloudPath.path)")
				}
			}
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func readsAndDeletesBelowFileReportAbsence(format: VaultTestFormat, stacking: Stacking) async throws {
			for cloudPath in Self.pathsBelowFile(for: stacking) {
				let fixture = try format.makeFixture(stacking: stacking)
				await #expect(throws: CloudProviderError.itemNotFound, "\(cloudPath.path)") { try await fixture.decorator.fetchItemMetadata(at: cloudPath) }
				await #expect(throws: CloudProviderError.itemNotFound, "\(cloudPath.path)") { try await fixture.decorator.fetchItemList(forFolderAt: cloudPath, withPageToken: nil) }
				await #expect(throws: CloudProviderError.itemNotFound, "\(cloudPath.path)") { try await fixture.decorator.deleteFolder(at: cloudPath) }
				let exists = try await fixture.decorator.checkForItemExistence(at: cloudPath)
				#expect(!exists, "\(cloudPath.path)")
				try await fixture.decorator.deleteFileIfExisting(at: cloudPath)
				try await fixture.decorator.deleteFolderIfExisting(at: cloudPath)
				#expect(Self.mutationCalls.isDisjoint(with: fixture.provider.calls), "\(cloudPath.path)")
			}
		}

		/// A symlink or an item of unknown type at a file's ciphertext name is no file, whatever name it reports.
		@Test(arguments: VaultTestFormat.allCases, [CloudItemType.symlink, .unknown])
		func readBelowNonFileAtFileNameThrowsItemTypeMismatch(format: VaultTestFormat, itemType: CloudItemType) async throws {
			let fixture = try format.makeFixture(stacking: .shortening)
			fixture.provider.metadataOverride = CloudProviderMock.reading([itemType], at: format.filePath("file1", in: VaultTestFormat.rootDirectory))
			let belowPath = CloudPath("/File 1/File 3")
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await fixture.decorator.fetchItemMetadata(at: belowPath) }
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await fixture.decorator.deleteFolderIfExisting(at: belowPath) }
		}

		/// A shortened file is a `.c9s` folder in vault format 7, which the provider below would delete as a folder.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func deleteFolderAndListingOfFileThrowItemTypeMismatch(format: VaultTestFormat, stacking: Stacking) async throws {
			let filePaths = [CloudPath("/File 1")] + (stacking == .shortening ? [CloudPath("/File 4 (Long)")] : [])
			for cloudPath in filePaths {
				let fixture = try format.makeFixture(stacking: stacking)
				await #expect(throws: CloudProviderError.itemTypeMismatch, "\(cloudPath.path)") { try await fixture.decorator.deleteFolder(at: cloudPath) }
				await #expect(throws: CloudProviderError.itemTypeMismatch, "\(cloudPath.path)") { try await fixture.decorator.fetchItemList(forFolderAt: cloudPath, withPageToken: nil) }
				#expect(Self.mutationCalls.isDisjoint(with: fixture.provider.calls), "\(cloudPath.path)")
			}
		}

		/// Another device replaced the folder `Directory 1` with a file after its dir ID and that of `Directory 2` were cached. A bypassing read drops them, so that a later listing doesn't list the cached directory.
		@Test(arguments: VaultTestFormat.allCases)
		func deleteFolderBelowFolderReplacedByFileDropsCachedDirIds(format: VaultTestFormat) async throws {
			let fixture = try format.makeFixture(stacking: .shortening)
			let folderPath = CloudPath("/Directory 1/Directory 2")
			_ = try await fixture.decorator.fetchItemList(forFolderAt: folderPath, withPageToken: nil)
			let referencePath = CloudPath(format.referencePath("dir1", in: VaultTestFormat.rootDirectory))
			switch format {
			case .vf6:
				try await fixture.provider.deleteFile(at: referencePath)
			case .vf7:
				try await fixture.provider.deleteFolder(at: referencePath)
			}
			let localURL = try makeLocalFile(in: tmpDirURL, content: "ciphertext1")
			_ = try await fixture.provider.uploadFile(from: localURL, to: CloudPath(format.filePath("dir1", in: VaultTestFormat.rootDirectory)), replaceExisting: false)
			let callCount = fixture.provider.calls.count
			await #expect(throws: CloudProviderError.itemNotFound) { try await fixture.decorator.deleteFolder(at: folderPath) }
			#expect(Self.mutationCalls.isDisjoint(with: fixture.provider.calls.dropFirst(callCount)))
			await #expect(throws: CloudProviderError.itemNotFound) { try await fixture.decorator.fetchItemList(forFolderAt: folderPath, withPageToken: nil) }
		}

		// MARK: - Requests

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func fetchItemMetadataRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			_ = try await fixture.decorator.fetchItemMetadata(at: CloudPath("/Directory 1/File 3"))
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemMetadata"], metadataReads: [format.filePath("file3", in: VaultTestFormat.directory1)], transfers: [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory)]))
		}

		/// The mock records a transfer only for a file it holds, so the download of the missing dir file records none.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func fetchItemMetadataBelowFileRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			await #expect(throws: CloudProviderError.itemNotFound) { try await fixture.decorator.fetchItemMetadata(at: CloudPath("/File 1/File 3")) }
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemMetadata"], metadataReads: [format.filePath("file1", in: VaultTestFormat.rootDirectory)]))
		}

		/// Vault format 6 reads the physical `.lng` file, and vault format 7 reads the `.c9s` folder and lists it.
		@Test(arguments: VaultTestFormat.allCases)
		func fetchItemMetadataBelowShortenedFileRequests(format: VaultTestFormat) async throws {
			let fixture = try format.makeFixture(stacking: .shortening)
			let requests = fixture.provider.recordingRequests()
			await #expect(throws: CloudProviderError.itemNotFound) { try await fixture.decorator.fetchItemMetadata(at: CloudPath("/File 4 (Long)/File 3")) }
			switch format {
			case .vf6:
				#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemMetadata"], metadataReads: ["\(VaultTestFormat.rootDirectory)/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"]))
			case .vf7:
				let c9sPath = "\(VaultTestFormat.rootDirectory)/\(VaultTestFormat.file4C9SName)"
				#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemMetadata", "fetchItemList"], metadataReads: [c9sPath], listings: [c9sPath]))
			}
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func fetchItemListRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			_ = try await fixture.decorator.fetchItemList(forFolderAt: CloudPath("/Directory 1"), withPageToken: nil)
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemList"], listings: [VaultTestFormat.directory1], transfers: [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory)]))
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func downloadFileRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			let localURL = tmpDirURL.appending(component: UUID().uuidString, directoryHint: .notDirectory)
			_ = try await fixture.decorator.downloadFile(from: CloudPath("/Directory 1/File 3"), to: localURL)
			#expect(try String(contentsOf: localURL, encoding: .utf8) == "cleartext3")
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "downloadFile"], transfers: [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory), format.filePath("file3", in: VaultTestFormat.directory1)]))
		}

		/// Vault format 6 checks that no folder holds the name, see its suite for that branch.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func uploadFileRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			let localURL = try makeLocalFile(in: tmpDirURL, content: "cleartext3")
			_ = try await fixture.decorator.uploadFile(from: localURL, to: CloudPath("/Directory 1/File 2"), replaceExisting: false)
			let dirFilePath = format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory)
			let filePath = format.filePath("file2", in: VaultTestFormat.directory1)
			switch format {
			case .vf6:
				#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemMetadata", "uploadFile"], metadataReads: [format.referencePath("file2", in: VaultTestFormat.directory1)], transfers: [dirFilePath, filePath], createdFiles: [filePath]))
			case .vf7:
				#expect(requests() == RecordedRequests(calls: ["downloadFile", "uploadFile"], transfers: [dirFilePath, filePath], createdFiles: [filePath]))
			}
			#expect(Data("ciphertext3".utf8) == fixture.provider.createdFiles[filePath])
		}

		/// Vault format 6 checks that no file holds the name, see its suite for that branch.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func createFolderRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			try await fixture.decorator.createFolder(at: CloudPath("/Directory 2"))
			let dirFilePath = format.dirFilePath("dir2", in: VaultTestFormat.rootDirectory)
			let directoryFolders = [VaultTestFormat.newDirectoryParent, VaultTestFormat.newDirectory]
			switch format {
			case .vf6:
				#expect(requests() == RecordedRequests(calls: ["fetchItemMetadata", "uploadFile", "createFolder", "createFolder"], metadataReads: [format.filePath("dir2", in: VaultTestFormat.rootDirectory)], transfers: [dirFilePath], createdFolders: directoryFolders, createdFiles: [dirFilePath]))
			case .vf7:
				#expect(requests() == RecordedRequests(calls: ["createFolder", "uploadFile", "createFolder", "createFolder"], transfers: [dirFilePath], createdFolders: [format.referencePath("dir2", in: VaultTestFormat.rootDirectory)] + directoryFolders, createdFiles: [dirFilePath]))
			}
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 2")) == fixture.provider.createdFiles[dirFilePath])
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func deleteFileRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			try await fixture.decorator.deleteFile(at: CloudPath("/Directory 1/File 3"))
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "deleteFile"], transfers: [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory)], deleted: [format.filePath("file3", in: VaultTestFormat.directory1)]))
		}

		/// The items of a directory are resolved concurrently, but only the reference of `Directory 2` sends requests, so their order is fixed.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func deleteFolderRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			try await fixture.decorator.deleteFolder(at: CloudPath("/Directory 1"))
			let transfers = [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory), format.dirFilePath("dir2", in: VaultTestFormat.directory1)]
			let deleted = [VaultTestFormat.directory2, VaultTestFormat.directory1, format.referencePath("dir1", in: VaultTestFormat.rootDirectory)]
			switch format {
			case .vf6:
				#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemList", "downloadFile", "fetchItemList", "deleteFolder", "deleteFolder", "deleteFile"], listings: [VaultTestFormat.directory1, VaultTestFormat.directory2], transfers: transfers, deleted: deleted))
			case .vf7:
				#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemList", "fetchItemList", "downloadFile", "fetchItemList", "deleteFolder", "deleteFolder", "deleteFolder"], listings: [VaultTestFormat.directory1, format.referencePath("dir2", in: VaultTestFormat.directory1), VaultTestFormat.directory2], transfers: transfers, deleted: deleted))
			}
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func moveFileRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			try await fixture.decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/Directory 1/File 2"))
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "moveFile"], transfers: [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory)], moved: [format.filePath("file1", in: VaultTestFormat.rootDirectory): format.filePath("file2", in: VaultTestFormat.directory1)]))
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func moveFolderRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			try fixture.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir1-id".utf8))
			try await fixture.decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2"))
			#expect(requests() == RecordedRequests(calls: [format.referenceMoveCall], moved: [format.referencePath("dir1", in: VaultTestFormat.rootDirectory): format.referencePath("dir2", in: VaultTestFormat.rootDirectory)]))
			#expect(try Data("dir1-id".utf8) == fixture.dirIdCache.get(CloudPath("/Directory 2")))
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		// MARK: - Cancellation

		/// The task is cancelled while the parent's dir ID is read. Deriving the ciphertext path comes next and fails before any cancellation check, because the cryptor mock doesn't know the name.
		@Test(arguments: VaultTestFormat.allCases, PathDerivingOperation.allCases)
		func operationThrowsPathErrorInTaskCancelledBeforeDerivingPath(format: VaultTestFormat, operation: PathDerivingOperation) async throws {
			let fixture = try format.makeFixture(stacking: .plain)
			fixture.provider.transferHook = { _, _ in
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let decorator = fixture.decorator
			let tmpDirURL = tmpDirURL
			let task = Task {
				try await operation.run(on: decorator, at: CloudPath("/Directory 1/Unknown"), localDirectoryURL: tmpDirURL)
			}
			await #expect(throws: CryptorMockError.notMocked) { try await cancellingValue(of: task) }
			#expect(task.isCancelled)
			#expect(fixture.provider.calls == ["downloadFile"])
		}

		// MARK: - Format

		/// The cryptor mock ignores the encoding, so a round trip through it can't show a wrong one.
		@Test(arguments: VaultTestFormat.allCases)
		func encodesNamesInFormatEncoding(format: VaultTestFormat) async throws {
			let fixture = try format.makeFixture(stacking: .plain)
			_ = try await fixture.decorator.fetchItemMetadata(at: CloudPath("/Directory 1/File 3"))
			#expect(!fixture.cryptor.encryptionEncodings.isEmpty)
			#expect(fixture.cryptor.encryptionEncodings.allSatisfy { $0 == format.fileNameEncoding })
			#expect(!fixture.cryptor.decryptionEncodings.isEmpty)
			#expect(fixture.cryptor.decryptionEncodings.allSatisfy { $0 == format.fileNameEncoding })
		}

		// MARK: - Internal

		func assertDeleted(_ temporaryURLs: [URL], sourceLocation: SourceLocation = #_sourceLocation) {
			#expect(!temporaryURLs.isEmpty, sourceLocation: sourceLocation)
			for temporaryURL in temporaryURLs {
				#expect(!FileManager.default.fileExists(atPath: temporaryURL.path), sourceLocation: sourceLocation)
			}
		}
	}
}
