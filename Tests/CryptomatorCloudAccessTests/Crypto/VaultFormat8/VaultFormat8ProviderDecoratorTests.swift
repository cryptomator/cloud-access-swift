//
//  VaultFormat8ProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 25.05.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

import Promises
import XCTest
@testable import CryptomatorCryptoLib

class VaultFormat8ProviderDecoratorTests: XCTestCase {
	let vaultPath = CloudPath("pathToVault")
	let cryptor = VaultFormat8CryptorMock(masterkey: Masterkey.createFromRaw(aesMasterKey: [UInt8](repeating: 0x55, count: 32), macMasterKey: [UInt8](repeating: 0x77, count: 32)))
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

	func testCreateFolder() {
		let expectation = XCTestExpectation(description: "createFolder")
		decorator.createFolder(at: CloudPath("/Directory 1")).then {
			XCTAssertEqual(3, self.provider.createdFolders.count)
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/99"))
			XCTAssertTrue(self.provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
			XCTAssertEqual(2, self.provider.createdFiles.count)
			XCTAssertNotNil(self.provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r"])
			XCTAssertNotNil(self.provider.createdFiles["pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/dirid.c9r"])
		}.catch { error in
			XCTFail("Error in promise: \(error)")
		}.always {
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: 1.0)
	}
}
