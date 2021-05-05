#!/bin/sh
if [ -f ./.integration-test-secrets.sh ]; then
  source ./.integration-test-secrets.sh
else
  echo "warning: .integration-test-secrets.sh could not be found, please see README for instructions"
fi
cat > ./Tests/CryptomatorCloudAccessIntegrationTests/IntegrationTestSecrets.swift << EOM
//
//  IntegrationTestSecrets.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 20.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccess
import Foundation

struct IntegrationTestSecrets {
	static let dropboxAccessToken = "${DROPBOX_ACCESS_TOKEN}"
	static let googleDriveClientId = "${GOOGLE_DRIVE_CLIENT_ID}"
	static let googleDriveRefreshToken = "${GOOGLE_DRIVE_REFRESH_TOKEN}"
	static let webDAVCredential = WebDAVCredential(baseURL: URL(string: "${WEBDAV_BASE_URL}")!, username: "${WEBDAV_USERNAME}", password: "${WEBDAV_PASSWORD}", allowedCertificate: nil)
	static let oneDriveClientId = "${ONEDRIVE_CLIENT_ID}"
	static let oneDriveRedirectUri = "${ONEDRIVE_REDIRECT_URI}://auth"
	static let oneDriveRefrehTokenData = "${ONEDRIVE_REFRESH_TOKEN_DATA}".data(using: .utf8)
	static let oneDriveAccountData = "${ONEDRIVE_ACCOUNT_DATA}".data(using: .utf8)
}
EOM
