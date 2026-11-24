//
//  VaultFormatError.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 29.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

enum VaultFormatError: Error {
	case encounteredUnrelatedFile
	case invalidNameFile
	/// A dir file is larger than `vaultDirFileMaxLength`, was read through an alias, or names the vault root or the directory of a folder that contains it. Also thrown where the root is given in place of a folder below it.
	case invalidDirectoryReference
}

func isInvalidNameFile(_ error: Error) -> Bool {
	return error as? VaultFormatError == .invalidNameFile
}
