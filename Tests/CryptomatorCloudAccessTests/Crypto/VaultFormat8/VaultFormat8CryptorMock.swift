//
//  VaultFormat8CryptorMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 25.05.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

/// `@unchecked Sendable`: restates the conformance of `CryptorMock`; this subclass adds no state.
public class VaultFormat8CryptorMock: CryptorMock, @unchecked Sendable {
	convenience init() {
		let dirIds = [
			"": "00AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		]
		let fileNames = [
			"dir1": "Directory 1"
		]
		self.init(dirIds: dirIds, fileNames: fileNames, contents: [:])
	}
}
