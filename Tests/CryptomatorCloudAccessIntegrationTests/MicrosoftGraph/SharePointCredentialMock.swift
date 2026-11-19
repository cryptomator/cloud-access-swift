//
//  SharePointCredentialMock.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 19.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
@testable import CryptomatorCloudAccessCore

extension MicrosoftGraphCredential {
	static func sharePointIntegrationTest() -> MicrosoftGraphCredential {
		return MicrosoftGraphCredential(identifier: "IntegrationTest-SharePoint", scopes: MicrosoftGraphType.sharePoint.scopes, tokenSource: ClientCredentialsTokenSource(fetchToken: fetchSharePointIntegrationTestToken), clientApplication: MSALPublicClientApplicationStub())
	}

	static func sharePointIntegrationTestInvalid() -> MicrosoftGraphCredential {
		return MicrosoftGraphCredential(identifier: "IntegrationTest-SharePoint-Invalid", scopes: MicrosoftGraphType.sharePoint.scopes, tokenSource: InvalidOAuthTokenSource(), clientApplication: MSALPublicClientApplicationStub())
	}

	private static let tokenEndpointSession = SplitURLSession(configuration: HTTPClientSupport.tokenEndpointConfiguration())

	/// Gets a token of the test tenant's Entra app.
	///
	/// - Throws: `OAuthTokenEndpointError` for an unsuccessful response, so that a server error counts as transient.
	@Sendable private static func fetchSharePointIntegrationTestToken() async throws -> String {
		let tenantID = try IntegrationTestSecrets.microsoftGraphSharePointTenantId
		let clientID = try IntegrationTestSecrets.microsoftGraphSharePointClientId
		let clientSecret = try IntegrationTestSecrets.microsoftGraphSharePointClientSecret
		let body = try await OAuthTokenEndpoint.post([
			("client_id", clientID),
			("client_secret", clientSecret),
			("scope", "https://graph.microsoft.com/.default"),
			("grant_type", "client_credentials")
		], host: "login.microsoftonline.com", path: "/\(tenantID)/oauth2/v2.0/token", on: tokenEndpointSession)
		return try JSONDecoder().decode(OAuthTokenResponse.self, from: body).accessToken
	}
}

/// The SharePoint test drive's identifier, looked up once per run. A failed lookup is forgotten, so that a retried fixture build looks it up again.
actor SharePointTestDrive {
	static let shared = SharePointTestDrive()

	private var lookup: Task<String, Error>?

	func identifier() async throws -> String {
		let lookup = lookup ?? Task { try await SharePointTestDrive.lookUpIdentifier() }
		self.lookup = lookup
		do {
			return try await lookup.value
		} catch {
			if self.lookup == lookup {
				self.lookup = nil
			}
			throw error
		}
	}

	/// Finds the drive by its name among the drives of the site at the configured URL.
	private static func lookUpIdentifier() async throws -> String {
		let discovery = MicrosoftGraphDiscovery(credential: SharedCredentials.sharePoint)
		let site = try await discovery.fetchSharePointSite(for: IntegrationTestSecrets.microsoftGraphSharePointSiteURL)
		let driveName = try IntegrationTestSecrets.microsoftGraphSharePointDriveName
		guard let drive = try await discovery.fetchSharePointDrives(for: site.identifier).first(where: { $0.name == driveName }) else {
			throw IntegrationTestError.driveNotFound(name: driveName)
		}
		return drive.identifier
	}
}
