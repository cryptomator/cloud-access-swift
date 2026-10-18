//
//  BackgroundURLSessionRegistry.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

/**
 Holds one background `URLSession` per identifier for the life of the process.

 A process may attach only one session to a background identifier, so all owners of an identifier share its session. A session is never invalidated, because that would cancel the transfers of its other owners. Releasing an owner must not stop its own transfers either.

 Every caller for an identifier must pass an equivalent configuration, because only the first one is used. This is not checked, so callers must not share an identifier between accounts.
 */
final class BackgroundURLSessionRegistry: Sendable {
	static let shared = BackgroundURLSessionRegistry()

	private let makeConfiguration: @Sendable (URLSessionConfiguration) -> URLSessionConfiguration
	private let sessions = OSAllocatedUnfairLock(initialState: [String: URLSession]())

	/// - Parameter makeConfiguration: Replaces the configuration of each session that the registry creates, e.g., with one that tests can mock.
	init(makeConfiguration: @escaping @Sendable (URLSessionConfiguration) -> URLSessionConfiguration = { $0 }) {
		self.makeConfiguration = makeConfiguration
	}

	/// - Precondition: `configuration` is a background configuration.
	func session(for configuration: URLSessionConfiguration) -> URLSession {
		guard let identifier = configuration.identifier else {
			preconditionFailure("A background session needs an identifier")
		}
		return sessions.withLockUnchecked { sessions in
			if let session = sessions[identifier] {
				return session
			}
			let session = URLSession(configuration: makeConfiguration(configuration), delegate: SplitURLSessionDelegate.shared, delegateQueue: nil)
			sessions[identifier] = session
			return session
		}
	}
}
