//
//  VaultFormat8Layout.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 05.03.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Cloud provider decorator for Cryptomator vaults in vault format 8 (without name shortening). To be fully compatible with vault format 8, stack it onto a `VaultFormat7ShorteningProviderDecorator` with the threshold of the vault configuration.
typealias VaultFormat8ProviderDecorator = VaultProviderDecorator<VaultFormat8Layout>

private extension CloudPath {
	func appendingDirIdFileComponent() -> CloudPath {
		return appendingPathComponent("dirid.c9r")
	}
}

private extension CloudProvider {
	func silentlyUploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) async throws {
		do {
			_ = try await uploadFile(from: localURL, to: cloudPath, replaceExisting: replaceExisting)
		} catch where !(error is CancellationError) {
			// The upload is optional.
		}
	}
}

/**
 The ciphertext layout of vault format 8, see the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.6/security/architecture/). It is that of vault format 7, since the new format "only" introduced a new vault configuration file. A folder creation also writes the encrypted dir ID to `dirid.c9r` in the new directory.
 */
struct VaultFormat8Layout: C9RVaultLayout {
	/// Encrypts the dir ID before any request, so that a failed encryption leaves nothing behind.
	func prepareFolderCreation(dirIdFileURL: URL, preparedFileURL: URL, in decorator: VaultFormat8ProviderDecorator) async throws {
		try await decorator.cryptor.encryptContent(from: dirIdFileURL, to: preparedFileURL)
	}

	/// This step is optional and creates a `dirid.c9r` file for recovery purposes, see https://github.com/cryptomator/cloud-access-swift/issues/10
	func didCreateDirectory(at dirPath: CloudPath, preparedFileURL: URL, in decorator: VaultFormat8ProviderDecorator) async throws {
		try await decorator.delegate.silentlyUploadFile(from: preparedFileURL, to: dirPath.appendingDirIdFileComponent(), replaceExisting: false)
	}
}
