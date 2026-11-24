//
//  CryptorMock+VaultFormats.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 24.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

extension CryptorMock {
	/// The cryptor of `CloudProviderMock.vaultFormat6()`.
	static func vaultFormat6() -> CryptorMock {
		return vaultFormat(dirNameRepeatCount: 33, fileNameRepeatCount: 26)
	}

	/// The cryptor of `CloudProviderMock.vaultFormat7()`.
	static func vaultFormat7() -> CryptorMock {
		return vaultFormat(dirNameRepeatCount: 55, fileNameRepeatCount: 44)
	}

	/// A cryptor that maps only the root's dir ID and `Directory 1`.
	static func vaultFormat8() -> CryptorMock {
		return CryptorMock(dirIds: ["": VaultTestFormat.encryptedRootDirId], fileNames: ["dir1": "Directory 1"], contents: [:])
	}

	/// The long names repeat `dir3`, `dir4` and `file4` to `file6` as often as the format needs to shorten them.
	private static func vaultFormat(dirNameRepeatCount: Int, fileNameRepeatCount: Int) -> CryptorMock {
		let dirIds = [
			"": VaultTestFormat.encryptedRootDirId,
			"dir1-id": "11BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
			"dir2-id": "22CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
			"dir3-id": "33DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
			"dir4-id": "44EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
		]
		let fileNames = [
			"dir1": "Directory 1",
			"dir2": "Directory 2",
			String(repeating: "dir3", count: dirNameRepeatCount): "Directory 3 (Long)",
			String(repeating: "dir4", count: dirNameRepeatCount): "Directory 4 (Long)",
			"file1": "File 1",
			"file2": "File 2",
			"file3": "File 3",
			String(repeating: "file4", count: fileNameRepeatCount): "File 4 (Long)",
			String(repeating: "file5", count: fileNameRepeatCount): "File 5 (Long)",
			String(repeating: "file6", count: fileNameRepeatCount): "File 6 (Long)"
		]
		let contents = [
			"ciphertext1": "cleartext1",
			"ciphertext2": "cleartext2",
			"ciphertext3": "cleartext3",
			"ciphertext4": "cleartext4",
			"ciphertext5": "cleartext5",
			"ciphertext6": "cleartext6"
		]
		return CryptorMock(dirIds: dirIds, fileNames: fileNames, contents: contents)
	}
}
