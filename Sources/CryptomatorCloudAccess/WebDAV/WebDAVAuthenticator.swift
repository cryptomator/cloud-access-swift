//
//  WebDAVAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 29.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum WebDAVAuthenticatorError: Error {
	case unsupportedProtocol
	case untrustedCertificate
}

public enum WebDAVAuthenticator {
	/**
	 Checks that the server of the credential speaks WebDAV and accepts the credential.

	 - Throws: `WebDAVAuthenticatorError.unsupportedProtocol` if the server isn't a WebDAV server, `WebDAVAuthenticatorError.untrustedCertificate` if its certificate isn't trusted, and otherwise the error of the failed request, e.g., `WebDAVError.httpError` with status 401 for a rejected credential.
	 */
	public static func verifyCredential(_ credential: WebDAVCredential) async throws {
		try await verifyClient(client: WebDAVClient(credential: credential))
	}

	static func verifyClient(client: WebDAVClient) async throws {
		do {
			try await checkServerCompatibility(client: client)
			try await tryAuthenticatedRequest(client: client)
		} catch {
			let nsError = error as NSError
			if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorServerCertificateUntrusted {
				throw WebDAVAuthenticatorError.untrustedCertificate
			} else {
				throw error
			}
		}
	}

	private static func checkServerCompatibility(client: WebDAVClient) async throws {
		let (httpResponse, _) = try await client.OPTIONS(url: client.baseURL)
		if httpResponse.value(forHTTPHeaderField: "DAV") == nil {
			throw WebDAVAuthenticatorError.unsupportedProtocol
		}
	}

	private static func tryAuthenticatedRequest(client: WebDAVClient) async throws {
		_ = try await client.PROPFIND(url: client.baseURL, depth: .zero)
	}
}
