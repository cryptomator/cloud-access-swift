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
	public static func verifyClient(client: WebDAVClient) -> Promise<Void> {
		return checkServerCompatibility(client: client).then {
			return self.tryAuthenticatedRequest(client: client)
		}.recover { error -> Promise<Void> in
			let nsError = error as NSError
			if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorServerCertificateUntrusted {
				return Promise(WebDAVAuthenticatorError.untrustedCertificate)
			} else {
				return Promise(error)
			}
		}
	}

	private static func checkServerCompatibility(client: WebDAVClient) -> Promise<Void> {
		return client.OPTIONS(url: client.baseURL).then { httpResponse, _ in
			if httpResponse.allHeaderFields["DAV"] != nil {
				return Promise(())
			} else {
				return Promise(WebDAVAuthenticatorError.unsupportedProcotol)
			}
		}
	}

	private static func tryAuthenticatedRequest(client: WebDAVClient) -> Promise<Void> {
		return client.PROPFIND(url: client.baseURL, depth: .zero).then { _, _ in
			return Promise(())
		}
	}
}
