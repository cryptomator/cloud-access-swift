//
//  S3Authenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum S3Authenticator {
	public static func verifyCredential(_ credential: S3Credential) async throws {
		let provider = try S3CloudProvider(credential: credential)
		_ = try await provider.fetchItemList(forFolderAt: .root, withPageToken: nil)
	}
}
