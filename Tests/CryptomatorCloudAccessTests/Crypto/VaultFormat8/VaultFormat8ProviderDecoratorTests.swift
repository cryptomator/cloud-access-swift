//
//  VaultFormat8ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 25.05.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class VaultFormat8ProviderDecoratorTests {
		let vaultPath: CloudPath
		let cryptor: CryptorMock
		let tmpDirURL: URL
		let provider: CloudProviderMock
		let decorator: VaultFormat8ProviderDecorator

		init() throws {
			let vaultPath = CloudPath("pathToVault")
			let cryptor = CryptorMock.vaultFormat8()
			let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			let provider = CloudProviderMock(folders: [VaultTestFormat.rootDirectory], files: [:])
			self.decorator = try VaultFormat8ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			self.vaultPath = vaultPath
			self.cryptor = cryptor
			self.tmpDirURL = tmpDirURL
			self.provider = provider
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func testCreateFolder() async throws {
			try await decorator.createFolder(at: CloudPath("/Directory 1"))
			#expect(provider.createdFolders.count == 3)
			#expect(provider.createdFolders.contains("\(VaultTestFormat.rootDirectory)/dir1.c9r"))
			#expect(provider.createdFolders.contains("pathToVault/d/99"))
			#expect(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
			#expect(provider.createdFiles.count == 2)
			#expect(provider.createdFiles["\(VaultTestFormat.rootDirectory)/dir1.c9r/dir.c9r"] != nil)
			#expect(provider.createdFiles["pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/dirid.c9r"] != nil)
		}

		/// `dirid.c9r` holds the dir ID of `dir.c9r` encrypted, and is uploaded last.
		@Test
		func createFolderRequests() async throws {
			let requests = provider.recordingRequests()
			let encryptedContents = OSAllocatedUnfairLock(initialState: [Data]())
			cryptor.encryptContentHook = { cleartextURL, _ in
				let cleartext = try Data(contentsOf: cleartextURL)
				encryptedContents.withLock { $0.append(cleartext) }
			}
			try await decorator.createFolder(at: CloudPath("/Directory 1"))
			let dirFilePath = "\(VaultTestFormat.rootDirectory)/dir1.c9r/dir.c9r"
			let dirIdFilePath = "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/dirid.c9r"
			#expect(requests() == RecordedRequests(calls: ["createFolder", "uploadFile", "createFolder", "createFolder", "uploadFile"], transfers: [dirFilePath, dirIdFilePath], createdFolders: ["\(VaultTestFormat.rootDirectory)/dir1.c9r", "pathToVault/d/99", "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"], createdFiles: [dirFilePath, dirIdFilePath]))
			#expect(Data("some-encrypted-content".utf8) == provider.createdFiles[dirIdFilePath])
			let dirId = try #require(provider.createdFiles[dirFilePath])
			#expect(encryptedContents.withLock { $0 } == [dirId])
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) == provider.createdFiles[dirFilePath])
		}

		@Test
		func createFolderWithCancellationAfterFirstRemoteChange() async throws {
			let decorator: VaultFormat8ProviderDecorator = decorator
			try await valueCancelledAfterFirstRemoteChange(of: provider) {
				try await decorator.createFolder(at: CloudPath("/Directory 1"))
			}
			#expect(provider.createdFolders.sorted() == ["\(VaultTestFormat.rootDirectory)/dir1.c9r", "pathToVault/d/99", "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"])
			#expect(provider.createdFiles.keys.sorted() == ["\(VaultTestFormat.rootDirectory)/dir1.c9r/dir.c9r", "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/dirid.c9r"])
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) != nil)
		}

		@Test
		func createFolderWithCancellationBeforeFirstRemoteChange() async throws {
			let decorator: VaultFormat8ProviderDecorator = decorator
			cryptor.encryptContentHook = { _, _ in
				withUnsafeCurrentTask { $0?.cancel() }
			}
			let creation = Task {
				try await decorator.createFolder(at: CloudPath("/Directory 1"))
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: creation) }
			#expect(creation.isCancelled)
			#expect(provider.createdFolders.isEmpty)
			#expect(provider.createdFiles.isEmpty)
		}

		@Test
		func createFolderWithFailingEncryption() async throws {
			cryptor.encryptContentHook = { _, _ in
				throw CryptorMockError.notMocked
			}
			await #expect(throws: CryptorMockError.notMocked) { try await decorator.createFolder(at: CloudPath("/Directory 1/Directory 1")) }
			#expect(provider.calls == [])
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		@Test
		func createFolderWithCancelledEncryption() async throws {
			cryptor.encryptContentHook = { _, _ in
				throw CancellationError()
			}
			await #expect(throws: CancellationError.self) { try await decorator.createFolder(at: CloudPath("/Directory 1/Directory 1")) }
			#expect(provider.calls == [])
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		@Test
		func createFolderWithFailingDirIdFileUpload() async throws {
			provider.transferHook = { cloudPath, _ in
				if cloudPath.lastPathComponent == "dirid.c9r" {
					throw CloudProviderError.noInternetConnection
				}
			}
			try await decorator.createFolder(at: CloudPath("/Directory 1"))
			#expect(provider.createdFiles.count == 1)
			#expect(provider.createdFiles["\(VaultTestFormat.rootDirectory)/dir1.c9r/dir.c9r"] != nil)
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		@Test
		func createFolderWithCancelledDirIdFileUpload() async throws {
			provider.transferHook = { cloudPath, _ in
				if cloudPath.lastPathComponent == "dirid.c9r" {
					throw CancellationError()
				}
			}
			await #expect(throws: CancellationError.self) { try await decorator.createFolder(at: CloudPath("/Directory 1")) }
			#expect(try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path) == [])
		}

		@Test
		func moveFolderWithMoveCompletedUpdatesCacheAndRethrows() async throws {
			let provider = CloudProviderMock(folders: ["\(VaultTestFormat.rootDirectory)/dir1.c9r"], files: [:])
			let cryptor = CryptorMock(dirIds: ["": VaultTestFormat.encryptedRootDirId], fileNames: ["dir1": "Directory 1", "dir2": "Directory 2"], contents: [:])
			let decorator = try VaultFormat8ProviderDecorator(provider: provider, vaultPath: vaultPath, cryptor: cryptor)
			try decorator.dirIdCache.addOrUpdate(CloudPath("/Directory 1"), dirId: Data("dir1-id".utf8))
			provider.mutationFailure = CloudProviderMock.failing("moveFolder", with: CloudProviderError.moveCompletedWithSourceRemaining)
			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 2")) }
			#expect(try Data("dir1-id".utf8) == decorator.dirIdCache.get(CloudPath("/Directory 2")))
			#expect(try decorator.dirIdCache.get(CloudPath("/Directory 1")) == nil)
		}

		@Test
		func throwsCancellationErrorInCancelledTask() async {
			await assertThrowsCancellationErrorInCancelledTask(decorator)
			#expect(provider.calls == [])
		}
	}
}
