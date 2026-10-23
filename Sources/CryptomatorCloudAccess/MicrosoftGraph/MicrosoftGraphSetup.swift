//
//  MicrosoftGraphSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import MSAL

/// The MSAL application of the app, which keeps the Microsoft logins.
///
/// `@unchecked Sendable`: `MSALPublicClientApplication` is not `Sendable`. This class only stores the reference immutably and never calls into it.
public final class MicrosoftGraphSetup: @unchecked Sendable {
	public let clientApplication: MSALPublicClientApplication

	public init(clientApplication: MSALPublicClientApplication) {
		self.clientApplication = clientApplication
	}
}
