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
}

public class DropboxAuthenticator {
	public static var pendingAuthentication: Promise<DropboxCredential>?
	private static let scopes = ["files.metadata.read", "files.metadata.write", "files.content.read", "files.content.write", "account_info.read"]
	private static let scopeRequest = DBScopeRequest(scopeType: DBScopeType.user, scopes: scopes, includeGrantedScopes: false)
	public init() {
		DropboxClientSetup.oneTimeSetup()
	}

	@available(iOSApplicationExtension, unavailable)
	public func authenticate(from viewController: UIViewController) -> Promise<DropboxCredential> {
		DropboxAuthenticator.pendingAuthentication?.reject(DropboxAuthenticatorError.authenticationFailed)
		let pendingAuthentication = Promise<DropboxCredential>.pending()
		DropboxAuthenticator.pendingAuthentication = pendingAuthentication
		DBClientsManager.authorize(fromControllerV2: .shared, controller: viewController, loadingStatusDelegate: nil, openURL: { url in
			UIApplication.shared.open(url, options: [:], completionHandler: nil)
		}, scopeRequest: DropboxAuthenticator.scopeRequest)
		return pendingAuthentication
	}

	public func processAuthentication(with tokenUID: String) throws {
		guard let pendingAuthentication = DropboxAuthenticator.pendingAuthentication else {
			throw DropboxAuthenticatorError.noPendingAuthentication
		}
		pendingAuthentication.fulfill(DropboxCredential(tokenUID: tokenUID))
	}
}
