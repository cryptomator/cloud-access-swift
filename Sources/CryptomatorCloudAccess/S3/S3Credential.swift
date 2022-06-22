//
//  S3Credential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 15.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct S3Credential: Codable {
	let accessKey: String
	let secretKey: String
	let url: URL
	let bucket: String
	let region: String
	let identifier: String

	public init(accessKey: String, secretKey: String, url: URL, bucket: String, region: String, identifier: String = UUID().uuidString) {
		self.accessKey = accessKey
		self.secretKey = secretKey
		self.url = url
		self.bucket = bucket
		self.region = region
		self.identifier = identifier
	}
}
