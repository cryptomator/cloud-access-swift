//
//  DropboxClientSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 06.10.20.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import ObjectiveDropboxOfficial

public enum DropboxClientSetup {
	public static var oneTimeSetup: () -> Void = {
		let config = DBTransportDefaultConfig(appKey: DropboxSetup.constants.appKey, appSecret: nil, userAgent: nil, asMemberId: nil, delegateQueue: nil, forceForegroundSession: DropboxSetup.constants.forceForegroundSession, sharedContainerIdentifier: DropboxSetup.constants.sharedContainerIdentifier, keychainService: DropboxSetup.constants.keychainService)
		DBClientsManager.setup(withTransport: config)
		return {}
	}()
}
