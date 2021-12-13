//
//  TLSCertificate.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 25.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct TLSCertificate {
	public let data: Data
	public let isTrusted: Bool
	public let fingerprint: String
}
