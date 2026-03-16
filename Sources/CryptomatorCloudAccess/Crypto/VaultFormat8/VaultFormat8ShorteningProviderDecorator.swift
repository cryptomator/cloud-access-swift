//
//  VaultFormat8ShorteningProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 05.03.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Cloud provider decorator for Cryptomator vaults in vault format 8 (only name shortening).

 With this decorator, it is expected that the cloud provider methods are being called with ciphertext paths. It transparently deflates/inflates filenames according to vault format 8, see the name shortening section at the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.6/security/architecture/#name-shortening).

 It's meaningless to use this shortening decorator without being decorated by an instance of `VaultFormat8ProviderDecorator` (crypto decorator). This shortening decorator explicitly only shortens the fourth path component relative to `vaultPath` if it exceeds the given `threshold`.
 */
class VaultFormat8ShorteningProviderDecorator: VaultFormat7ShorteningProviderDecorator {
	override init(delegate: CloudProvider, vaultPath: CloudPath, threshold: Int) throws {
		try super.init(delegate: delegate, vaultPath: vaultPath, threshold: threshold)
	}

	@available(*, unavailable)
	convenience init(delegate: CloudProvider, vaultPath: CloudPath) throws {
		try self.init(delegate: delegate, vaultPath: vaultPath, threshold: 220)
	}
}
