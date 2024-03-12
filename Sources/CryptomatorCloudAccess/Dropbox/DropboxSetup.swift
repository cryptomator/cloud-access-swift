//
//  DropboxSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 01.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Setup for the Dropbox Cloud Provider

 - Important: The `DropboxSetup.constants` must be set only once before any interaction with the `DropboxCloudProvider` or `DropboxCredentials` takes place.
 */
public class DropboxSetup {
	public static var constants: DropboxSetup!

	let appKey: String
	let sharedContainerIdentifier: String?
	let keychainService: String?
	let forceForegroundSession: Bool

	/**
	 - Parameter appKey: The consumer app key associated with the app that is integrating with the Dropbox API.
	 - Parameter sharedContainerIdentifier: The identifier for the shared container into which files in background URL sessions should be downloaded. This needs to be set when downloading via an app extension.
	 - Parameter keychainService: The service name for the keychain. Leave nil to use default
	 - Parameter forceForegroundSession: If set to true, all network requests are made on foreground sessions (by default, most upload/download operations are performed with a background session).
	 */
	public init(appKey: String, sharedContainerIdentifier: String?, keychainService: String?, forceForegroundSession: Bool) {
		self.appKey = appKey
		self.sharedContainerIdentifier = sharedContainerIdentifier
		self.keychainService = keychainService
		self.forceForegroundSession = forceForegroundSession
	}
}
