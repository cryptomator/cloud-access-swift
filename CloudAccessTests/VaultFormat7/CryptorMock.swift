//
//  CryptorMock.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 10.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
@testable import CryptomatorCryptoLib

public class CryptorMock: Cryptor {
	
	let cleartextNames = [
		"file1": "File 1",
		"file2": "File 2",
		"dir1": "Directory 1",
		"file3": "File 3",
	]
	
	let ciphertextNames: [String: String]
	
	let dirIds = [
		"": "00AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"dir1-id": "11BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
	]
	
	public override init(masterKey: Masterkey) {
		var reversed = [String: String]()
		for (key, value) in cleartextNames {
			reversed[value] = key
		}
		self.ciphertextNames = reversed
		super.init(masterKey: masterKey)
	}
	
	public override func encryptDirId(_ dirIdStr: String) -> String? {
		return dirIds[dirIdStr]
	}
	
	public override func encryptFileName(_ cleartextName: String, dirId: Data, encoding: FileNameEncoding = .base64url) -> String? {
		return ciphertextNames[cleartextName]
	}
	
	public override func decryptFileName(_ ciphertextName: String, dirId: Data, encoding: FileNameEncoding = .base64url) -> String? {
		return cleartextNames[ciphertextName]
	}
	
}
