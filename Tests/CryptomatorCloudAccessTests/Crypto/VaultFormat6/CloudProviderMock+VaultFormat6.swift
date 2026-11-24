//
//  CloudProviderMock+VaultFormat6.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

extension CloudProviderMock {
	/**
	 A vault of format 6, whose names `CryptorMock.vaultFormat6()` encrypts:
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
	static func vaultFormat6() -> CloudProviderMock {
		let root = VaultTestFormat.rootDirectory
		let folders: Set = [
			root,
			VaultTestFormat.directory1,
			VaultTestFormat.directory2,
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
			"\(root)/0dir1": dir1IdData,
			"\(root)/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": dir3IdData,
			"\(root)/file1": file1CiphertextData,
			"\(root)/file2": file2CiphertextData,
			"\(root)/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng": file4CiphertextData,
			"\(root)/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng": file5CiphertextData,
			"\(VaultTestFormat.directory1)/0dir2": dir2IdData,
			"\(VaultTestFormat.directory1)/file3": file3CiphertextData,
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/5ZIVSZELKKXO66ALXML6ORP32HF3OLAL.lng": dir4IdData,
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng": file6CiphertextData,
			"pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng": dir3NameData,
			"pathToVault/m/5Z/IV/5ZIVSZELKKXO66ALXML6ORP32HF3OLAL.lng": dir4NameData,
			"pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng": file4NameData,
			"pathToVault/m/CI/VV/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng": file5NameData,
			"pathToVault/m/LT/GF/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng": file6NameData
		]
		return CloudProviderMock(folders: folders, files: files)
	}
}
