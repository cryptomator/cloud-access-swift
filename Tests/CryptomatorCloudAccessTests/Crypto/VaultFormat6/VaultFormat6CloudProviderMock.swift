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
		// Precompute data to improve type-check performance during compilation
		let dir1IdData = Data("dir1-id".utf8)
		let dir2IdData = Data("dir2-id".utf8)
		let dir3IdData = Data("dir3-id".utf8)
		let dir4IdData = Data("dir4-id".utf8)
		let dir3NameData = Data("0\(String(repeating: "dir3", count: 33))".utf8)
		let dir4NameData = Data("0\(String(repeating: "dir4", count: 33))".utf8)
		let file1CiphertextData = Data("ciphertext1".utf8)
		let file2CiphertextData = Data("ciphertext2".utf8)
		let file3CiphertextData = Data("ciphertext3".utf8)
		let file4CiphertextData = Data("ciphertext4".utf8)
		let file5CiphertextData = Data("ciphertext5".utf8)
		let file6CiphertextData = Data("ciphertext6".utf8)
		let file4NameData = Data(String(repeating: "file4", count: 26).utf8)
		let file5NameData = Data(String(repeating: "file5", count: 26).utf8)
		let file6NameData = Data(String(repeating: "file6", count: 26).utf8)
		let files = [
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1": dir1IdData,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": dir3IdData,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1": file1CiphertextData,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file2": file2CiphertextData,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng": file4CiphertextData,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng": file5CiphertextData,
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": dir2IdData,
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3": file3CiphertextData,
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/5ZIVSZELKKXO66ALXML6ORP32HF3OLAL.lng": dir4IdData,
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng": file6CiphertextData,
			"pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": dir3NameData,
			"pathToVault/m/5Z/IV/5ZIVSZELKKXO66ALXML6ORP32HF3OLAL.lng": dir4NameData,
			"pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng": file4NameData,
			"pathToVault/m/CI/VV/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng": file5NameData,
			"pathToVault/m/LT/GF/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng": file6NameData
		]
		self.init(folders: folders, files: files)
	}
}
