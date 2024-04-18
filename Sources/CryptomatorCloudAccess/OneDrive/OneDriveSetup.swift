//
//  OneDriveSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import MSAL

public class OneDriveSetup {
	public static var constants: OneDriveSetup!

	public let clientApplication: MSALPublicClientApplication
	public let sharedContainerIdentifier: String?

	public init(clientApplication: MSALPublicClientApplication, sharedContainerIdentifier: String?) {
		self.clientApplication = clientApplication
		self.sharedContainerIdentifier = sharedContainerIdentifier
	}
}
