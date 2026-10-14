//
//  VaultFormat8ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 25.05.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultFormat8ProviderDecoratorTests: XCTestCase {
	let vaultPath = CloudPath("pathToVault")
	let cryptor = VaultFormat8CryptorMock()
	var tmpDirURL: URL!
	var provider: CloudProviderMock!
	var decorator: VaultFormat8ProviderDecorator!

	override func setUpWithError() throws {
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		provider = CloudProviderMock(folders: Set(), files: [:])
		decorator = try VaultFormat8ProviderDecorator(delegate: provider, vaultPath: vaultPath, cryptor: cryptor)
	}

	override func tearDownWithError() throws {
		decorator = nil
		provider = nil
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testCreateFolder() async throws {
		try await decorator.createFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
		XCTAssertEqual(2, provider.createdFiles.count)
		XCTAssertNotNil(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r"])
		XCTAssertNotNil(provider.createdFiles["pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/dirid.c9r"])
	}

	func testCreateFolderWithCancellationAfterFirstRemoteChange() async throws {
		let decorator: VaultFormat8ProviderDecorator = decorator
		try await valueCancelledAfterFirstRemoteChange(of: provider) {
			try await decorator.createFolder(at: CloudPath("/Directory 1"))
		}
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r", "pathToVault/d/99", "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"], provider.createdFolders.sorted())
		XCTAssertEqual(["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r", "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/dirid.c9r"], provider.createdFiles.keys.sorted())
		XCTAssertNotNil(try decorator.dirIdCache.get(CloudPath("/Directory 1")))
	}

	func testCreateFolderWithCancellationBeforeFirstRemoteChange() async throws {
		let decorator: VaultFormat8ProviderDecorator = decorator
		cryptor.encryptContentHook = { _, _ in
			withUnsafeCurrentTask { $0?.cancel() }
		}
		let creation = Task {
			try await decorator.createFolder(at: CloudPath("/Directory 1"))
		}
		await XCTAssertThrowsErrorAsync(try await value(of: creation)) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertTrue(creation.isCancelled)
		XCTAssertTrue(provider.createdFolders.isEmpty)
		XCTAssertTrue(provider.createdFiles.isEmpty)
	}

	func testCreateFolderWithFailingEncryption() async throws {
		cryptor.encryptContentHook = { _, _ in
			throw CryptorMockError.notMocked
		}
		await XCTAssertThrowsErrorAsync(try await decorator.createFolder(at: CloudPath("/Directory 1"))) { error in
			XCTAssertEqual(CryptorMockError.notMocked, error as? CryptorMockError)
		}
		XCTAssertTrue(provider.createdFolders.isEmpty)
		XCTAssertTrue(provider.createdFiles.isEmpty)
		XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path))
	}

	func testCreateFolderWithCancelledEncryption() async throws {
		cryptor.encryptContentHook = { _, _ in
			throw CancellationError()
		}
		await XCTAssertThrowsErrorAsync(try await decorator.createFolder(at: CloudPath("/Directory 1"))) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertTrue(provider.createdFolders.isEmpty)
		XCTAssertTrue(provider.createdFiles.isEmpty)
		XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path))
	}

	func testCreateFolderWithFailingDirIdFileUpload() async throws {
		provider.transferHook = { cloudPath, _ in
			if cloudPath.lastPathComponent == "dirid.c9r" {
				throw CloudProviderError.noInternetConnection
			}
		}
		try await decorator.createFolder(at: CloudPath("/Directory 1"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertNotNil(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r"])
		XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path))
	}

	func testCreateFolderWithCancelledDirIdFileUpload() async throws {
		provider.transferHook = { cloudPath, _ in
			if cloudPath.lastPathComponent == "dirid.c9r" {
				throw CancellationError()
			}
		}
		await XCTAssertThrowsErrorAsync(try await decorator.createFolder(at: CloudPath("/Directory 1"))) { error in
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertEqual([], try FileManager.default.contentsOfDirectory(atPath: decorator.tmpDirURL.path))
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(decorator)
		XCTAssertEqual([], provider.calls)
	}
}
