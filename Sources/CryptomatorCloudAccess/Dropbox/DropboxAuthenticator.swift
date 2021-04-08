//
//  DropboxAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif
import Foundation
import ObjectiveDropboxOfficial
import Promises

public enum DropboxAuthenticatorError: Error {
	case authenticationFailed
	case noPendingAuthentication
	case userCanceled
}

public class DropboxAuthenticator {
	public static var pendingAuthentication: Promise<DropboxCredential>?

	public init() {
		DropboxClientSetup.oneTimeSetup()
	}

	@available(iOSApplicationExtension, unavailable)
	public func authenticate(from viewController: UIViewController) -> Promise<DropboxCredential> {
		// TODO: Check for existing authentication?

		DropboxAuthenticator.pendingAuthentication?.reject(DropboxAuthenticatorError.authenticationFailed)
		let pendingAuthentication = Promise<DropboxCredential>.pending()
		DropboxAuthenticator.pendingAuthentication = pendingAuthentication
		DBClientsManager.authorize(fromController: .shared, controller: viewController) { url in
			UIApplication.shared.open(url, options: [:], completionHandler: nil)
		}
		return pendingAuthentication
	}

	public func processAuthentication(with tokenUid: String) throws {
		guard let pendingAuthentication = DropboxAuthenticator.pendingAuthentication else {
			throw DropboxAuthenticatorError.noPendingAuthentication
		}
		pendingAuthentication.fulfill(DropboxCredential(tokenUid: tokenUid))
	}

	public func deauthenticate() -> Promise<Void> {
		DBClientsManager.unlinkAndResetClients()
		// TODO: set all existing DropboxCredential.authorizedClients to nil
		return Promise(())
	}
}
