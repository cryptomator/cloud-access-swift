//
//  WebDAVCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 29.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct WebDAVCredential: Codable {
	public let baseURL: URL
	public let username: String
	public let password: String
	public let allowedCertificate: Data?
	public let identifier: String

	public init(baseURL: URL, username: String, password: String, allowedCertificate: Data?, identifier: String = UUID().uuidString) {
		self.baseURL = baseURL
		self.username = username
		self.password = password
		self.allowedCertificate = allowedCertificate
		self.identifier = identifier
	}
}
