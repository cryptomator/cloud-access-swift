//
//  CloudProviderMock+VaultFormat7.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

extension CloudProviderMock {
	/**
	 A vault of format 7, whose names `CryptorMock.vaultFormat7()` encrypts:
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
	static func vaultFormat7() -> CloudProviderMock {
		let root = VaultTestFormat.rootDirectory
		let folders: Set = [
			root,
			"\(root)/dir1.c9r",
			"\(root)/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s", // (dir3){55}.c9r
			"\(root)/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s", // (file4){44}.c9r
			"\(root)/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s", // (file5){44}.c9r
			VaultTestFormat.directory1,
			"\(VaultTestFormat.directory1)/dir2.c9r",
			VaultTestFormat.directory2,
			VaultTestFormat.directory3,
			"\(VaultTestFormat.directory3)/ImoW6Jb8d-kdR00uEadGd1_TJDM=.c9s", // (dir4){55}.c9r
			"\(VaultTestFormat.directory3)/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s", // (file6){44}.c9r
			VaultTestFormat.directory4
		]
		// Precompute repeated strings to improve type-check performance during compilation
		let dir1IdData = Data("dir1-id".utf8)
		let dir2IdData = Data("dir2-id".utf8)
		let dir3IdData = Data("dir3-id".utf8)
		let dir4IdData = Data("dir4-id".utf8)
		let dir3NameData = Data("\(String(repeating: "dir3", count: 55)).c9r".utf8)
		let dir4NameData = Data("\(String(repeating: "dir4", count: 55)).c9r".utf8)
		let file1CiphertextData = Data("ciphertext1".utf8)
		let file2CiphertextData = Data("ciphertext2".utf8)
		let file3CiphertextData = Data("ciphertext3".utf8)
		let file4CiphertextData = Data("ciphertext4".utf8)
		let file5CiphertextData = Data("ciphertext5".utf8)
		let file6CiphertextData = Data("ciphertext6".utf8)
		let file4NameData = Data("\(String(repeating: "file4", count: 44)).c9r".utf8)
		let file5NameData = Data("\(String(repeating: "file5", count: 44)).c9r".utf8)
		let file6NameData = Data("\(String(repeating: "file6", count: 44)).c9r".utf8)
		let files = [
			"\(root)/dir1.c9r/dir.c9r": dir1IdData,
			"\(root)/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/dir.c9r": dir3IdData,
			"\(root)/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s": dir3NameData,
			"\(root)/file1.c9r": file1CiphertextData,
			"\(root)/file2.c9r": file2CiphertextData,
			"\(root)/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r": file4CiphertextData,
			"\(root)/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s": file4NameData,
			"\(root)/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/contents.c9r": file5CiphertextData,
			"\(root)/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/name.c9s": file5NameData,
			"\(VaultTestFormat.directory1)/dir2.c9r/dir.c9r": dir2IdData,
			"\(VaultTestFormat.directory1)/file3.c9r": file3CiphertextData,
			"\(VaultTestFormat.directory3)/ImoW6Jb8d-kdR00uEadGd1_TJDM=.c9s/dir.c9r": dir4IdData,
			"\(VaultTestFormat.directory3)/ImoW6Jb8d-kdR00uEadGd1_TJDM=.c9s/name.c9s": dir4NameData,
			"\(VaultTestFormat.directory3)/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s/contents.c9r": file6CiphertextData,
			"\(VaultTestFormat.directory3)/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s/name.c9s": file6NameData
		]
		return CloudProviderMock(folders: folders, files: files)
	}
}
