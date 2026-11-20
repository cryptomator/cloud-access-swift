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

	static let vaultPath = CloudPath("pathToVault")
	static let rootDirectory = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	static let directory1 = "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
	static let directory2 = "pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
	/// The directory of every folder that a test creates, because the cryptor mock maps every unknown dir ID to it.
	static let newDirectory = "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
	/// The directories of the root and of `dir1-id` to `dir4-id`, by path below `pathToVault/d`, which a provider of nested references holds.
	static let nestedDirectories = ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"]

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

	func makeCryptor() -> CryptorMock {
		switch self {
		case .vf6:
			return VaultFormat6CryptorMock()
		case .vf7:
			return VaultFormat7CryptorMock()
		}
	}

	/// Returns a fixture of the format's decorator, stacked onto a fresh vault mock as `stacking` says.
	func makeFixture(stacking: Stacking) throws -> VaultTestFixture {
		switch self {
		case .vf6:
			let cryptor = VaultFormat6CryptorMock()
			let fixture = try VaultFormat6Fixture(stacking: stacking, vaultPath: Self.vaultPath, cryptor: cryptor)
			return VaultTestFixture(provider: fixture.provider, cryptor: cryptor, decorator: fixture.decorator, dirIdCache: fixture.decorator.dirIdCache, tmpDirURL: fixture.decorator.tmpDirURL, shorteningTmpDirURL: fixture.shorteningDecorator?.tmpDirURL)
		case .vf7:
			let cryptor = VaultFormat7CryptorMock()
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

	/// Returns a provider that holds the given folder references and, unless one replaces it, that of `Directory 1`. A key is the directory below `pathToVault/d` and the encrypted folder name (e.g. `11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2`), a value the dir ID. The directories of the root and of `dir1-id` to `dir4-id` exist. A download of a file at a path of `aliasedDownloads` reports an alias.
	func makeNestedProvider(references: [String: String], aliasedDownloads: Set<String> = []) -> CloudProviderMock {
		let references = ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1": "dir1-id"].merging(references) { $1 }
		let referenceLocations = references.keys.map { CloudPath("pathToVault/d/\($0)") }.map { (name: $0.lastPathComponent, directory: $0.deletingLastPathComponent().path) }
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
		let localURL = localDirectoryURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
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

extension UnitTests {
	final class VaultProviderDecoratorTests {
		let tmpDirURL: URL

		init() throws {
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
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
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: files)
			let cryptor = CryptorMock(dirIds: ["": "00AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"], fileNames: ["nested": "a/b", "parent": "..", "file1": "File 1"], contents: [:])
			let decorator = try format.makeDecorator(provider: provider, cryptor: cryptor)
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
			#expect([CloudPath("/File 1")] == itemList.items.map(\.cloudPath))
		}

		@Test(arguments: VaultTestFormat.allCases)
		func fetchItemListWithTooLargeDirFileThrowsInvalidDirectoryReference(format: VaultTestFormat) async throws {
			let provider = format.makeNestedProvider(references: ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1": String(repeating: "a", count: vaultDirFileMaxLength + 1)])
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
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
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
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
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
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
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
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
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
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
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
			let cleartextURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try Data(count: 1024 * 1024).write(to: cleartextURL)
			let uploadProvider = CloudProviderMock(folders: [], files: [:])
			_ = try await format.makeDecorator(provider: uploadProvider, cryptor: cryptor).uploadFile(from: cleartextURL, to: cloudPath, replaceExisting: false)
			let decorator = try format.makeDecorator(provider: CloudProviderMock(folders: [], files: uploadProvider.createdFiles), cryptor: cryptor)
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
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
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
			let progress = Progress(totalUnitCount: 1)
			let transfer = SuspendedTransfer()
			fixture.provider.transferHook = transfer.run
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File 1"), replaceExisting: false, progress: progress, onTaskCreation: nil)
			}
			await transfer.suspended.wait()
			#expect(progress.fractionCompleted > 0)
			#expect(progress.fractionCompleted < 1)
			transfer.resume()
			let metadata = try await cancellingValue(of: upload)
			#expect(progress.fractionCompleted == 1)
			#expect(fixture.provider.createdFiles == [format.filePath("file1", in: VaultTestFormat.rootDirectory): Data("ciphertext1".utf8)])
			#expect(metadata.name == "File 1")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/File 1")
			#expect(try FileManager.default.contentsOfDirectory(atPath: fixture.tmpDirURL.path) == [])
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func uploadFileWithFailingTransfer(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let decorator = fixture.decorator
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
			let progress = Progress(totalUnitCount: 1)
			let transfer = SuspendedTransfer()
			fixture.provider.transferHook = transfer.run
			let upload = Task {
				try await decorator.uploadFile(from: localURL, to: CloudPath("/File 1"), replaceExisting: false, progress: progress, onTaskCreation: nil)
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
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext1".write(to: localURL, atomically: true, encoding: .utf8)
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
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
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
			let targetURL = tmpDirURL.appendingPathComponent("target", isDirectory: false)
			try "cleartext1".write(to: targetURL, atomically: true, encoding: .utf8)
			let linkURL = tmpDirURL.appendingPathComponent("link", isDirectory: false)
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
			let encryptedURLs = OSAllocatedUnfairLock(initialState: [URL]())
			fixture.cryptor.encryptContentHook = { cleartextURL, _ in
				encryptedURLs.withLock { $0.append(cleartextURL) }
			}
			_ = try await fixture.decorator.uploadFile(from: linkURL, to: CloudPath("/File 1"), replaceExisting: false)
			#expect(encryptedURLs.withLock { $0 }.map(\.lastPathComponent) == ["target"])
		}

		@Test(arguments: VaultTestFormat.allCases, [false, true])
		func uploadFileFromUnusableSourceThrowsBeforeAnyRequest(format: VaultTestFormat, sourceIsFolder: Bool) async throws {
			let fixture = try format.makeFixture(stacking: .plain)
			let sourceURL = sourceIsFolder ? tmpDirURL : tmpDirURL.appendingPathComponent("link", isDirectory: false)
			if !sourceIsFolder {
				try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: tmpDirURL.appendingPathComponent("missing", isDirectory: false))
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
				try await decorator.createFolder(at: CloudPath("/Directory 1"))
			}
			let referenceFolders = format == .vf7 ? [format.referencePath("dir1", in: VaultTestFormat.rootDirectory)] : []
			#expect(fixture.provider.createdFolders.sorted() == (referenceFolders + ["pathToVault/d/99", VaultTestFormat.newDirectory]).sorted())
			#expect(Array(fixture.provider.createdFiles.keys) == [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory)])
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 1")) != nil)
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
			fixture.provider.afterMutationHook = CloudProviderMock.failing("deleteFolder", with: CloudProviderError.deletionIncomplete, at: [VaultTestFormat.directory1])
			await #expect(throws: CloudProviderError.deletionIncomplete) { try await fixture.decorator.deleteFolder(at: CloudPath("/Directory 1")) }
			#expect(!fixture.provider.deleted.contains(format.referencePath("dir1", in: VaultTestFormat.rootDirectory)))
			#expect(try Data("dir1-id".utf8) == fixture.dirIdCache.get(CloudPath("/Directory 1")))
		}

		/// On Google Drive, a shortcut can share a genuine dir file's name, and a read of that path can reach the shortcut's target. The walk refuses it, so the directory of `Directory 2` is neither listed nor deleted.
		@Test(arguments: VaultTestFormat.allCases)
		func deleteFolderKeepsFolderWhoseDirFileDownloadsThroughAlias(format: VaultTestFormat) async throws {
			let provider = format.makeNestedProvider(references: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2": "dir2-id"], aliasedDownloads: [format.dirFilePath("dir2", in: VaultTestFormat.directory1)])
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
			let provider = format.makeNestedProvider(references: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2": "dir2-id"], aliasedDownloads: [ancestorDirFilePath])
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
			let provider = format.makeNestedProvider(references: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2": "dir2-id"], aliasedDownloads: [dirFilePath])
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
			let provider = format.makeNestedProvider(references: ["11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2": "dir2-id", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/dir5": "dir1-id"])
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
			let provider = format.makeNestedProvider(references: ["00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1": "", "00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir2": "dir2-id"])
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
			fixture.provider.afterMutationHook = CloudProviderMock.failing(format.referenceMoveCall, with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await fixture.decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2")) }
			#expect(try Data("dir1-id".utf8) == fixture.dirIdCache.get(CloudPath("/Directory 2")))
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		/// A move that failed otherwise left no usable target, so the cache must not map one.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func moveFolderWithOtherMoveErrorSkipsCacheUpdate(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			try fixture.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir1-id".utf8))
			fixture.provider.afterMutationHook = CloudProviderMock.failing(format.referenceMoveCall, with: CloudProviderError.itemAlreadyExists)
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await fixture.decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2")) }
			#expect(try fixture.dirIdCache.get(CloudPath("/Directory 2")) == nil)
			#expect(try Data("dir1-id".utf8) == fixture.dirIdCache.get(CloudPath("/Directory 1")))
		}

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func throwsCancellationErrorInCancelledTask(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			await assertThrowsCancellationErrorInCancelledTask(fixture.decorator)
			#expect(fixture.provider.calls == [])
		}

		// MARK: - Requests

		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func fetchItemMetadataRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			_ = try await fixture.decorator.fetchItemMetadata(at: CloudPath("/Directory 1/File 3"))
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "fetchItemMetadata"], metadataReads: [format.filePath("file3", in: VaultTestFormat.directory1)], transfers: [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory)]))
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
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			_ = try await fixture.decorator.downloadFile(from: CloudPath("/Directory 1/File 3"), to: localURL)
			#expect(try String(contentsOf: localURL, encoding: .utf8) == "cleartext3")
			#expect(requests() == RecordedRequests(calls: ["downloadFile", "downloadFile"], transfers: [format.dirFilePath("dir1", in: VaultTestFormat.rootDirectory), format.filePath("file3", in: VaultTestFormat.directory1)]))
		}

		/// Vault format 6 checks that no folder holds the name, see its suite for that branch.
		@Test(arguments: VaultTestFormat.allCases, Stacking.allCases)
		func uploadFileRequests(format: VaultTestFormat, stacking: Stacking) async throws {
			let fixture = try format.makeFixture(stacking: stacking)
			let requests = fixture.provider.recordingRequests()
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext3".write(to: localURL, atomically: true, encoding: .utf8)
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
			let directoryFolders = ["pathToVault/d/99", VaultTestFormat.newDirectory]
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
