//
//  VaultFormat6CryptorMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation

public class VaultFormat6CryptorMock: CryptorMock {
	convenience init(masterkey: Masterkey) {
		let dirIds = [
			"": "00AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			"dir1-id": "11BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
			"dir2-id": "22CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
			"dir3-id": "33DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
			"dir4-id": "44EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
		]
		let fileNames = [
			"dir1": "Directory 1",
			"dir2": "Directory 2",
			String(repeating: "dir3", count: 33): "Directory 3 (Long)",
			String(repeating: "dir4", count: 33): "Directory 4 (Long)",
			"file1": "File 1",
			"file2": "File 2",
			"file3": "File 3",
			String(repeating: "file4", count: 26): "File 4 (Long)",
			String(repeating: "file5", count: 26): "File 5 (Long)",
			String(repeating: "file6", count: 26): "File 6 (Long)"
		]
		let contents = [
			"ciphertext1": "cleartext1",
			"ciphertext2": "cleartext2",
			"ciphertext3": "cleartext3",
			"ciphertext4": "cleartext4",
			"ciphertext5": "cleartext5",
			"ciphertext6": "cleartext6"
		]
		self.init(masterkey: masterkey, dirIds: dirIds, fileNames: fileNames, contents: contents)
	}
}
