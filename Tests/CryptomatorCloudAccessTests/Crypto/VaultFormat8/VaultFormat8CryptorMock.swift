//
//  VaultFormat8CryptorMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 25.05.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation

public class VaultFormat8CryptorMock: CryptorMock {
	convenience init(masterkey: Masterkey) {
		let dirIds = [
			"": "00AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		]
		let fileNames = [
			"dir1": "Directory 1"
		]
		self.init(masterkey: masterkey, dirIds: dirIds, fileNames: fileNames, contents: [:])
	}
}
