//
//  VaultFormatError.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 29.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

enum VaultFormatError: Error {
	case encounteredUnrelatedFile
	case invalidNameFile
	/// A dir file names the vault root, or the directory of a folder that contains it, or a cleartext path names no folder below the root.
	case invalidDirectoryReference
}

func isInvalidNameFile(_ error: Error) -> Bool {
	return error as? VaultFormatError == .invalidNameFile
}
