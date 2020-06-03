//
//  CloudAuthentication.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
import UIKit

/**
 Protocol for a cloud authentication.

 This authentication object will be used to authenticate the requests for its corresponding `CloudProvider` implementation.
 */
public protocol CloudAuthentication {
	/**
	 Initiate authentication flow from specified view controller.

	 - Parameter viewController: The `UIViewController` with which to render the authentication flow. Please ensure that this is the top-most view controller, so that the authorization view displays correctly.
	 - Returns: Empty promise. If the authentication fails, promise is rejected with:
	   - `CloudAuthenticationError.userCanceled` if the user cancels the authentication.
	 */
	func authenticate(from viewController: UIViewController) -> Promise<Void>

	/**
	 Check if the current session is authenticated.

	 Note that this doesn't guarantee that a request will get a valid authentication, as the authentication state could be expired or invalid.

	 - Returns: Promise with `true` if the current session is authenticated, otherwise `false`.
	 */
	func isAuthenticated() -> Promise<Bool>

	/**
	 Get username of the current authentication.

	 - Returns: Promise with username. If the request fails, promise is rejected with:
	   - `CloudAuthenticationError.notAuthenticated` if the user is not authenticated.
	   - `CloudAuthenticationError.noUsername` if the user is authenticated but there is no username.
	 */
	func getUsername() -> Promise<String>

	/**
	 Deauthenticate current session.

	 Removes stored authentication state from the cache and clears all stored access tokens. User might need to enter his credentials again after calling this API.

	 - Returns: Empty promise.
	 */
	func deauthenticate() -> Promise<Void>
}
