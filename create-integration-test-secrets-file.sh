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
	static let oneDriveClientId = "${ONEDRIVE_CLIENT_ID}"
	static let oneDriveRedirectUri = "${ONEDRIVE_REDIRECT_URI_SCHEME}://auth"
	static let oneDriveRefreshToken = "${ONEDRIVE_REFRESH_TOKEN}"
	static let pCloudAppKey = "${PCLOUD_APP_KEY}"
	static let pCloudAccessToken = "${PCLOUD_ACCESS_TOKEN}"
	static let pCloudHTTPAPIHostName = "${PCLOUD_HTTP_API_HOST_NAME}"
	static let s3AccessKey = "${S3_ACCESS_KEY}"
	static let s3SecretKey = "${S3_SECRET_KEY}"
	static let s3URL = URL(string: "${S3_URL}")!
	static let s3Bucket = "${S3_BUCKET}"
	static let s3RegionName = "${S3_REGION}"
	static let webDAVCredential = WebDAVCredential(baseURL: URL(string: "${WEBDAV_BASE_URL}")!, username: "${WEBDAV_USERNAME}", password: "${WEBDAV_PASSWORD}", allowedCertificate: nil)
}
EOM
