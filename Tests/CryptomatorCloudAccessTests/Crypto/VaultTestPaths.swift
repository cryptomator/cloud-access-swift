//
//  VaultTestPaths.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 24.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
@testable import CryptomatorCloudAccessCore

extension VaultTestFormat {
	static let vaultPath = CloudPath("pathToVault")
	/// The encrypted dir ID of the root, which every `CryptorMock` factory returns for the empty dir ID.
	static let encryptedRootDirId = "00AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	static let rootDirectory = "pathToVault/d/\(nestedDirectories[0])"
	static let directory1 = "pathToVault/d/\(nestedDirectories[1])"
	static let directory2 = "pathToVault/d/\(nestedDirectories[2])"
	static let directory3 = "pathToVault/d/\(nestedDirectories[3])"
	static let directory4 = "pathToVault/d/\(nestedDirectories[4])"
	/// The directory of every folder that a test creates, because the cryptor mock maps every unknown dir ID to it.
	static let newDirectory = "pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
	/// The directories of the root and of `dir1-id` to `dir4-id`, by path below `pathToVault/d`, which a provider of nested references holds. The root's comes first.
	static let nestedDirectories = ["\(encryptedRootDirId.prefix(2))/\(encryptedRootDirId.dropFirst(2))", "11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "22/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", "44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"]
}
