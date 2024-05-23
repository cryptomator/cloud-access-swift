//
//  VaultFormat7CloudProviderMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

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
public class VaultFormat7CloudProviderMock: CloudProviderMock {
	convenience init() {
		let folders: Set = [
			"pathToVault",
			"pathToVault/d",
			"pathToVault/d/00",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r",
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s", // (dir3){55}.c9r
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s", // (file4){44}.c9r
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s", // (file5){44}.c9r
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r",
			"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/ImoW6Jb8d-kdR00uEadGd1_TJDM=.c9s", // (dir4){55}.c9r
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s", // (file6){44}.c9r
			"pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
		]
		let files = [
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/dir1.c9r/dir.c9r": Data("dir1-id".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/dir.c9r": Data("dir3-id".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/kUDsIDxDMxx1lK0CD1ZftCF376Y=.c9s/name.c9s": Data("\(String(repeating: "dir3", count: 55)).c9r".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1.c9r": Data("ciphertext1".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file2.c9r": Data("ciphertext2".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/contents.c9r": Data("ciphertext4".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/9j5eVKQZdTojV6zlbxhcCLD_8bs=.c9s/name.c9s": Data("\(String(repeating: "file4", count: 44)).c9r".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/contents.c9r": Data("ciphertext5".utf8),
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/aw1qoKFUVs_FnB_n3lGtqKpyIeA=.c9s/name.c9s": Data("\(String(repeating: "file5", count: 44)).c9r".utf8),
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/dir2.c9r/dir.c9r": Data("dir2-id".utf8),
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3.c9r": Data("ciphertext3".utf8),
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/ImoW6Jb8d-kdR00uEadGd1_TJDM=.c9s/dir.c9r": Data("dir4-id".utf8),
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/ImoW6Jb8d-kdR00uEadGd1_TJDM=.c9s/name.c9s": Data("\(String(repeating: "dir4", count: 55)).c9r".utf8),
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s/contents.c9r": Data("ciphertext6".utf8),
			"pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/nSuAAJhIy1kp2_GdVZ0KgqaLJ-U=.c9s/name.c9s": Data("\(String(repeating: "file6", count: 44)).c9r".utf8)
		]
		self.init(folders: folders, files: files)
	}
}
