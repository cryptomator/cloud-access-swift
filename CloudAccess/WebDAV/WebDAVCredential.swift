//
//  WebDAVCredential.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 29.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct WebDAVCredential {
	let baseURL: URL
	let username: String
	let password: String
	let allowedCertificate: Data?
}
