//
//  VaultConfigHelper.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 22.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum VaultConfigHelper {
	public static func getType(for vaultConfig: UnverifiedVaultConfig) -> VaultConfigType {
		switch vaultConfig.keyId {
		case let .some(keyId) where keyId.hasPrefix("hub+https"):
			return .hub
		case let .some(keyId) where keyId.hasPrefix("masterkeyfile:masterkey.cryptomator"):
			return .masterkeyFile
		default:
			return .unknown
		}
	}
}

public enum VaultConfigType {
	case masterkeyFile
	case hub
	case unknown
}
