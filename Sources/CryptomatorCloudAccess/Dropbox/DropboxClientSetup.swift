//
//  DropboxClientSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 06.10.20.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
@preconcurrency import SwiftyDropbox

public enum DropboxClientSetup {
	static let keychainStorage = DropboxKeychainStorage(keychainService: DropboxSetup.constants.keychainService ?? Bundle.main.bundleIdentifier ?? "")
	private static let lockedOneTimeSetup: OSAllocatedUnfairLock<@Sendable () -> Void> = {
		DropboxClientsManager.setupWithAppKeyMultiUser(DropboxSetup.constants.appKey, tokenUid: nil, secureStorageAccess: keychainStorage)
		return OSAllocatedUnfairLock(initialState: {})
	}()

	public static var oneTimeSetup: @Sendable () -> Void {
		get { lockedOneTimeSetup.withLock { $0 } }
		set { lockedOneTimeSetup.withLock { $0 = newValue } }
	}
}
