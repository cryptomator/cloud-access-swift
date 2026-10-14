//
//  MicrosoftGraphSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 16.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import MSAL
import os

/// `@unchecked Sendable`: `MSALPublicClientApplication` is not `Sendable`. This class only stores the reference immutably and never calls into it.
public final class MicrosoftGraphSetup: @unchecked Sendable {
	private static let lockedConstants = OSAllocatedUnfairLock<MicrosoftGraphSetup?>(initialState: nil)
	public static var constants: MicrosoftGraphSetup! {
		get { lockedConstants.withLock { $0 } }
		set { lockedConstants.withLock { $0 = newValue } }
	}

	public let clientApplication: MSALPublicClientApplication
	public let sharedContainerIdentifier: String?

	public init(clientApplication: MSALPublicClientApplication, sharedContainerIdentifier: String?) {
		self.clientApplication = clientApplication
		self.sharedContainerIdentifier = sharedContainerIdentifier
	}
}
