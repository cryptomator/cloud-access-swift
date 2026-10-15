//
//  PCloudSetup.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

public final class PCloudSetup: Sendable {
	private static let lockedConstants = OSAllocatedUnfairLock<PCloudSetup?>(initialState: nil)
	public static var constants: PCloudSetup! {
		get { lockedConstants.withLock { $0 } }
		set { lockedConstants.withLock { $0 = newValue } }
	}

	public let appKey: String
	public let sharedContainerIdentifier: String?

	public init(appKey: String, sharedContainerIdentifier: String?) {
		self.appKey = appKey
		self.sharedContainerIdentifier = sharedContainerIdentifier
	}
}
