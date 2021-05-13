//
//  OneDriveSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import MSAL
public enum OneDriveSetup {
	public static var clientApplication: MSALPublicClientApplication!
	public static var sharedContainerIdentifier: String?
}
