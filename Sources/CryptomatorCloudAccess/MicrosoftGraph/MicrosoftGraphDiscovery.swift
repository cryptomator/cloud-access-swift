//
//  MicrosoftGraphDiscovery.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 02.12.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation

public final class MicrosoftGraphDiscovery: Sendable {
	private let client: MicrosoftGraphHTTPClient

	public convenience init(credential: MicrosoftGraphCredential) {
		self.init(client: .foreground(tokenSource: credential.tokenSource))
	}

	init(client: MicrosoftGraphHTTPClient) {
		self.client = client
	}

	/**
	 Fetches the SharePoint site at the URL.

	 - Throws: `SharePointURLValidationError` for a URL outside SharePoint, `CancellationError` or `CloudProviderError.noInternetConnection` for a cancelled request or a failed connection, and otherwise what the request throws.
	 */
	public func fetchSharePointSite(for siteURL: URL) async throws -> MicrosoftGraphSite {
		return try await perform {
			try siteURL.validateForSharePoint()
			guard let hostName = siteURL.absoluteURL.host else {
				throw URLError(.badURL)
			}
			let site = try await client.site(hostName: hostName, percentEncodedSitePath: siteURL.absoluteURL.path(percentEncoded: true))
			return MicrosoftGraphSite(identifier: site.id, displayName: site.displayName)
		}
	}

	/**
	 Fetches the document libraries of the SharePoint site.

	 - Throws: `CancellationError` or `CloudProviderError.noInternetConnection` for a cancelled request or a failed connection, and otherwise what the request throws.
	 */
	public func fetchSharePointDrives(for siteID: String) async throws -> [MicrosoftGraphDrive] {
		return try await perform {
			let collection = try await client.drives(ofSite: siteID)
			return collection.value.map { MicrosoftGraphDrive(identifier: $0.id, name: $0.name) }
		}
	}

	/**
	 Fetches the drive of the identifier.

	 - Throws: `CancellationError` or `CloudProviderError.noInternetConnection` for a cancelled request or a failed connection, and otherwise what the request throws.
	 */
	public func fetchDrive(for driveID: String) async throws -> MicrosoftGraphDrive {
		return try await perform {
			let drive = try await client.drive(id: driveID)
			return MicrosoftGraphDrive(identifier: drive.id, name: drive.name)
		}
	}

	/// Converts the cancellation and connection errors of a fetch with `MicrosoftGraphCloudProvider.convertStandardError(_:)`.
	private func perform<T>(_ fetch: () async throws -> T) async throws -> T {
		do {
			return try await fetch()
		} catch {
			throw MicrosoftGraphCloudProvider.convertStandardError(error)
		}
	}
}
