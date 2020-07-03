//
//  WebDAVAuthenticator.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 29.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

enum WebDAVAuthenticatorError: Error {
	case unsupportedProcotol
	case untrustedCertificate
}

public class WebDAVAuthenticator {
	public func createAuthenticatedClient(credential: WebDAVCredential, sharedContainerIdentifier: String) -> Promise<WebDAVClient> {
		let client = WebDAVClient(credential: credential, sharedContainerIdentifier: sharedContainerIdentifier)
		return checkServerCompatibility(client: client).then {
			return self.tryAuthenticatedRequest(client: client)
		}.then { () -> WebDAVClient in
			return client
		}.recover { error -> Promise<WebDAVClient> in
			let nsError = error as NSError
			if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorServerCertificateUntrusted {
				return Promise(WebDAVAuthenticatorError.untrustedCertificate)
			} else {
				return Promise(error)
			}
		}
	}

	private func checkServerCompatibility(client: WebDAVClient) -> Promise<Void> {
		return client.OPTIONS(url: client.baseURL).then { httpResponse, _ in
			if httpResponse.allHeaderFields["DAV"] != nil {
				return Promise(())
			} else {
				return Promise(WebDAVAuthenticatorError.unsupportedProcotol)
			}
		}
	}

	private func tryAuthenticatedRequest(client: WebDAVClient) -> Promise<Void> {
		return client.PROPFIND(url: client.baseURL, depth: .zero).then { _, _ in
			return Promise(())
		}
	}
}
