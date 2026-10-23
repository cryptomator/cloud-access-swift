//
//  S3Credential.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 15.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct S3Credential: Codable, Equatable, Sendable {
	public let accessKey: String
	public let secretKey: String
	public let url: URL
	public let bucket: String
	public let region: String
	/// Whether every request addresses the bucket in the path, for a server that can't address it in the host, e.g., without wildcard DNS. With `nil` or `false`, the bucket name and the host decide.
	public let forcePathStyle: Bool?
	public let identifier: String

	public init(accessKey: String, secretKey: String, url: URL, bucket: String, region: String, forcePathStyle: Bool? = nil, identifier: String = UUID().uuidString) {
		self.accessKey = accessKey
		self.secretKey = secretKey
		self.url = url
		self.bucket = bucket
		self.region = region
		self.forcePathStyle = forcePathStyle
		self.identifier = identifier
	}
}
