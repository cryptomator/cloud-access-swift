//
//  MicrosoftGraphDrive.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 02.12.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

public struct MicrosoftGraphDrive: Codable {
	public let identifier: String
	public let name: String?
}

extension MicrosoftGraphDrive: Equatable {
	public static func == (lhs: MicrosoftGraphDrive, rhs: MicrosoftGraphDrive) -> Bool {
		return lhs.identifier == rhs.identifier
	}
}
