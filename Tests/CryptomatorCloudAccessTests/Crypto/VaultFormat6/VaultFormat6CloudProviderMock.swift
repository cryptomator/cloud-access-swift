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
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1": "dir1-id".data(using: .utf8)!,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": "dir3-id".data(using: .utf8)!,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1": "ciphertext1".data(using: .utf8)!,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file2": "ciphertext2".data(using: .utf8)!,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng": "ciphertext4".data(using: .utf8)!,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng": "ciphertext5".data(using: .utf8)!,
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": "dir2-id".data(using: .utf8)!,
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3": "ciphertext3".data(using: .utf8)!,
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/5ZIVSZELKKXO66ALXML6ORP32HF3OLAL.lng": "dir4-id".data(using: .utf8)!,
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng": "ciphertext6".data(using: .utf8)!,
			"pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": "0\(String(repeating: "dir3", count: 33))".data(using: .utf8)!,
			"pathToVault/m/5Z/IV/5ZIVSZELKKXO66ALXML6ORP32HF3OLAL.lng": "0\(String(repeating: "dir4", count: 33))".data(using: .utf8)!,
			"pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng": String(repeating: "file4", count: 26).data(using: .utf8)!,
			"pathToVault/m/CI/VV/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng": String(repeating: "file5", count: 26).data(using: .utf8)!,
			"pathToVault/m/LT/GF/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng": String(repeating: "file6", count: 26).data(using: .utf8)!
		]
		self.init(folders: folders, files: files)
	}
}
