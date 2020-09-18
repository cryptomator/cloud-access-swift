//
//  VaultFormat6CloudProviderMock.swift
//  CloudAccessTests
//
//  Created by Tobias Hagemann on 26.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
@testable import CloudAccess

/**
 ```
 pathToVault
 ├─ Directory 1
 │  ├─ Directory 2
 │  └─ File 3
 ├─ File 1
 └─ File 2
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
			"pathToVault/d/22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
		]
		let files = [
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1": "dir1-id".data(using: .utf8)!,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1": "ciphertext1".data(using: .utf8)!,
			"pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file2": "ciphertext2".data(using: .utf8)!,
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/0dir2": "dir2-id".data(using: .utf8)!,
			"pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/file3": "ciphertext3".data(using: .utf8)!
		]
		self.init(folders: folders, files: files)
	}
}
