//
//  VaultFormat8ProviderDecorator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 05.03.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Cloud provider decorator for Cryptomator vaults in vault format 8 (without name shortening).

 With this decorator, you can call the cloud provider methods with cleartext paths (relative to `vaultPath`) and the decorator passes ciphertext paths (absolute) to the delegate. It transparently encrypts/decrypts filenames and file contents according to vault format 8, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.6/security/architecture/).

 Use the factory methods to create a new crypto decorator. In order to be fully compatible with vault format 8, pass an instance of `VaultFormat8ShorteningProviderDecorator` (shortening decorator) as the delegate.

 The implementation of this decorator is identical to vault format 7 since the new format "only" introduced a new vault configuration file.
 */
class VaultFormat8ProviderDecorator: VaultFormat7ProviderDecorator {}
