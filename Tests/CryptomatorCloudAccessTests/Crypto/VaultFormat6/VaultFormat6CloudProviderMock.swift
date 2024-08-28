//
//  VaultFormat6CloudProviderMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
@testable import CryptomatorCloudAccess

/**
 ```
 pathToVault
 ├─ Directory 1
 │  ├─ Directory 2
 │  └─ File 3
 ├─ Directory 3 (Long)
 │  ├─ Directory 4 (Long)
 │  └─ File 6 (Long)
 ├─ File 1
 ├─ File 2
 ├─ File 4 (Long)
 └─ File 5 (Long)
 ```
 */
public class VaultFormat6CloudProviderMock: CloudProviderMock {
	convenience init() {
		let folders: Set = [
			"pathToVault",
			"pathToVault/d",
			"pathToVault/d/00",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
			"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
			"pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
		]
		let files = [
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1": Data("dir1-id".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": Data("dir3-id".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1": Data("ciphertext1".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file2": Data("ciphertext2".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng": Data("ciphertext4".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng": Data("ciphertext5".utf8),
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": Data("dir2-id".utf8),
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3": Data("ciphertext3".utf8),
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/5ZIVSZELKKXO66ALXML6ORP32HF3OLAL.lng": Data("dir4-id".utf8),
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng": Data("ciphertext6".utf8),
			"pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": Data("0\(String(repeating: "dir3", count: 33))".utf8),
			"pathToVault/m/5Z/IV/5ZIVSZELKKXO66ALXML6ORP32HF3OLAL.lng": Data("0\(String(repeating: "dir4", count: 33))".utf8),
			"pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng": Data(String(repeating: "file4", count: 26).utf8),
			"pathToVault/m/CI/VV/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng": Data(String(repeating: "file5", count: 26).utf8),
			"pathToVault/m/LT/GF/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng": Data(String(repeating: "file6", count: 26).utf8)
		]
		self.init(folders: folders, files: files)
	}
}
