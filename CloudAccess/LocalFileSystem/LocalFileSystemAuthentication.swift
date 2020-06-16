//
//  LocalFileSystemAuthentication.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 03.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
public class LocalFileSystemAuthentication: CloudAuthentication {
	public func authenticate(from _: UIViewController) -> Promise<Void> {
		return Promise(())
	}

	public func isAuthenticated() -> Promise<Bool> {
		return Promise(true)
	}

	public func getUsername() -> Promise<String> {
		return Promise("")
	}

	public func deauthenticate() -> Promise<Void> {
		return Promise(())
	}
}
