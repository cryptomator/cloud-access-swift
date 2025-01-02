//
//  MicrosoftGraphScopes.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 31.12.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum MicrosoftGraphScopes {
	public static let oneDrive = ["https://graph.microsoft.com/Files.ReadWrite"]
	public static let sharePoint = ["https://graph.microsoft.com/Files.ReadWrite", "https://graph.microsoft.com/Sites.Read.All"]
}
