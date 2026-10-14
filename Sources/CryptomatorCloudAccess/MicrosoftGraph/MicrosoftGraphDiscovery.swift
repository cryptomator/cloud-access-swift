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

	public init(credential: MicrosoftGraphCredential) {
		self.client = MicrosoftGraphHTTPClient(accessTokenProvider: credential.accessTokenProvider, configuration: .default)
	}

	public func fetchSharePointSite(for siteURL: URL) async throws -> MicrosoftGraphSite {
		let request = try sharePointSiteRequest(for: siteURL)
		let data = try await sendExpectingOK(request)
		let site = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.Site.self, from: data)
		return MicrosoftGraphSite(identifier: site.id, displayName: site.displayName)
	}

	public func fetchSharePointDrives(for siteID: String) async throws -> [MicrosoftGraphDrive] {
		let request = try sharePointDrivesRequest(for: siteID)
		let data = try await sendExpectingOK(request)
		let collection = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.Drive>.self, from: data)
		return collection.value.map { MicrosoftGraphDrive(identifier: $0.id, name: $0.name) }
	}

	public func fetchDrive(for driveID: String) async throws -> MicrosoftGraphDrive {
		let request = try sharePointDriveRequest(for: driveID)
		let data = try await sendExpectingOK(request)
		let drive = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.Drive.self, from: data)
		return MicrosoftGraphDrive(identifier: drive.id, name: drive.name)
	}

	// MARK: - Requests

	func sharePointSiteRequest(for siteURL: URL) throws -> URLRequest {
		try siteURL.validateForSharePoint()
		guard let hostName = siteURL.host else {
			throw MicrosoftGraphError.invalidURL
		}
		let serverRelativePath = siteURL.relativePath
		guard let url = URL(string: "\(MicrosoftGraphAPI.baseURL)/sites/\(hostName):\(serverRelativePath)") else {
			throw MicrosoftGraphError.invalidURL
		}
		return URLRequest(url: url)
	}

	func sharePointDrivesRequest(for siteID: String) throws -> URLRequest {
		guard let url = URL(string: "\(MicrosoftGraphAPI.baseURL)/sites/\(siteID)/drives") else {
			throw MicrosoftGraphError.invalidURL
		}
		return URLRequest(url: url)
	}

	func sharePointDriveRequest(for driveID: String) throws -> URLRequest {
		guard let url = URL(string: "\(MicrosoftGraphAPI.baseURL)/drives/\(driveID)") else {
			throw MicrosoftGraphError.invalidURL
		}
		return URLRequest(url: url)
	}

	// MARK: - Execution

	private func sendExpectingOK(_ request: URLRequest) async throws -> Data {
		let (response, data): (HTTPURLResponse, Data)
		do {
			(response, data) = try await client.data(for: request)
		} catch {
			throw convertStandardError(error)
		}
		guard response.statusCode == 200 else {
			throw mapStatusCodeToError(response.statusCode)
		}
		return data
	}

	// MARK: - Helpers

	private func mapStatusCodeToError(_ statusCode: Int) -> Error {
		switch statusCode {
		case 404:
			return CloudProviderError.itemNotFound
		case 401:
			return CloudProviderError.unauthorized
		case 507:
			return CloudProviderError.quotaInsufficient
		default:
			return MicrosoftGraphError.unexpectedHTTPStatusCode(code: statusCode)
		}
	}

	private func convertStandardError(_ error: Error) -> Error {
		if isCancellationError(error) {
			return CancellationError()
		}
		return error
	}
}
