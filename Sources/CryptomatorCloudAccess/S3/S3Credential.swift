//
//  S3Credential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 15.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct S3Credential: Codable, Equatable {
	public let accessKey: String
	public let secretKey: String
	public let url: URL
	public let bucket: String
	public let region: String
	public let identifier: String

	public init(accessKey: String, secretKey: String, url: URL, bucket: String, region: String, identifier: String = UUID().uuidString) {
		self.accessKey = accessKey
		self.secretKey = secretKey
		self.url = url
		self.bucket = bucket
		self.region = region
		self.identifier = identifier
	}
}
