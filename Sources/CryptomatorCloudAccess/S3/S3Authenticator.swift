//
//  S3Authenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

public enum S3Authenticator {
	public static func verifyCredential(_ credential: S3Credential) -> Promise<Void> {
		let provider: S3CloudProvider
		do {
			provider = try S3CloudProvider(credential: credential)
		} catch {
			return Promise(error)
		}
		return provider.fetchItemList(forFolderAt: .root, withPageToken: nil).then { _ in
			// no-op
		}
	}
}
