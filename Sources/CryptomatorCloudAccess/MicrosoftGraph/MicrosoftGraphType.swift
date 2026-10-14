//
//  MicrosoftGraphType.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 10.03.25.
//  Copyright © 2025 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

public enum MicrosoftGraphType: Codable, DatabaseValueConvertible, Sendable {
	case oneDrive
	case sharePoint

	public var scopes: [String] {
		switch self {
		case .oneDrive:
			return ["https://graph.microsoft.com/Files.ReadWrite"]
		case .sharePoint:
			return ["https://graph.microsoft.com/Sites.ReadWrite.All"]
		}
	}
}
