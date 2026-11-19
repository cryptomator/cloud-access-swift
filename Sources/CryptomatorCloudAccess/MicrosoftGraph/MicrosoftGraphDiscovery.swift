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

	public func fetchSharePointSite(for siteURL: URL) async throws -> MicrosoftGraphSite {
		try siteURL.validateForSharePoint()
		guard let hostName = siteURL.absoluteURL.host else {
			throw URLError(.badURL)
		}
		let site = try await client.site(hostName: hostName, percentEncodedSitePath: siteURL.absoluteURL.path(percentEncoded: true))
		return MicrosoftGraphSite(identifier: site.id, displayName: site.displayName)
	}

	public func fetchSharePointDrives(for siteID: String) async throws -> [MicrosoftGraphDrive] {
		let collection = try await client.drives(ofSite: siteID)
		return collection.value.map { MicrosoftGraphDrive(identifier: $0.id, name: $0.name) }
	}

	public func fetchDrive(for driveID: String) async throws -> MicrosoftGraphDrive {
		let drive = try await client.drive(id: driveID)
		return MicrosoftGraphDrive(identifier: drive.id, name: drive.name)
	}
}
