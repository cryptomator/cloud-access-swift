//
//  MicrosoftGraphDiscovery.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 02.12.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import MSGraphClientModels
@preconcurrency import MSGraphClientSDK

/// Safe to share across threads, because the requests of the HTTP client are issued on the main actor.
public final class MicrosoftGraphDiscovery: Sendable {
	private let client: MSHTTPClient

	public init(credential: MicrosoftGraphCredential) {
		self.client = MSClientFactory.createHTTPClient(with: credential.authProvider, andSessionConfiguration: .default)
	}

	public func fetchSharePointSite(for siteURL: URL) async throws -> MicrosoftGraphSite {
		let request = try sharePointSiteRequest(for: siteURL)
		let data = try await executeMSURLSessionDataTaskWithErrorMapping(with: request)
		let site = try MSGraphSite(data: data)
		return MicrosoftGraphSite(identifier: site.entityId, displayName: site.displayName)
	}

	public func fetchSharePointDrives(for siteID: String) async throws -> [MicrosoftGraphDrive] {
		let request = try sharePointDrivesRequest(for: siteID)
		let data = try await executeMSURLSessionDataTaskWithErrorMapping(with: request)
		let collection = try MSCollection(data: data)
		return collection.value.compactMap { item in
			guard let drive = MSGraphDrive(dictionary: item as? [AnyHashable: Any]) else {
				return nil
			}
			return MicrosoftGraphDrive(identifier: drive.entityId, name: drive.name)
		}
	}

	public func fetchDrive(for driveID: String) async throws -> MicrosoftGraphDrive {
		let request = try sharePointDriveRequest(for: driveID)
		let data = try await executeMSURLSessionDataTaskWithErrorMapping(with: request)
		let drive = try MSGraphDrive(data: data)
		return MicrosoftGraphDrive(identifier: drive.entityId, name: drive.name)
	}

	// MARK: - Requests

	func sharePointSiteRequest(for siteURL: URL) throws -> NSMutableURLRequest {
		try siteURL.validateForSharePoint()
		guard let hostName = siteURL.host else {
			throw MicrosoftGraphError.invalidURL
		}
		let serverRelativePath = siteURL.relativePath
		guard let url = URL(string: "\(MSGraphBaseURL)/sites/\(hostName):\(serverRelativePath)") else {
			throw MicrosoftGraphError.invalidURL
		}
		return NSMutableURLRequest(url: url)
	}

	func sharePointDrivesRequest(for siteID: String) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(MSGraphBaseURL)/sites/\(siteID)/drives") else {
			throw MicrosoftGraphError.invalidURL
		}
		return NSMutableURLRequest(url: url)
	}

	func sharePointDriveRequest(for driveID: String) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(MSGraphBaseURL)/drives/\(driveID)") else {
			throw MicrosoftGraphError.invalidURL
		}
		return NSMutableURLRequest(url: url)
	}

	// MARK: - Execution

	private func executeRawMSURLSessionDataTask(with request: NSMutableURLRequest) async throws -> (Data?, URLResponse?) {
		let urlRequest = request as URLRequest
		HTTPDebugLogger.logRequest(urlRequest)
		return try await withMainActorSDKContinuation { resumer in
			let task = MSURLSessionDataTask(request: (urlRequest as NSURLRequest).mutableCopy() as? NSMutableURLRequest, client: self.client) { data, response, error in
				if let response {
					HTTPDebugLogger.logResponse(response, with: data, or: nil)
				}
				if let error {
					resumer.resume(throwing: self.convertStandardError(error))
				} else {
					resumer.resume(returning: (data, response))
				}
			}
			task?.execute()
		}
	}

	private func executeMSURLSessionDataTask(with request: NSMutableURLRequest) async throws -> (Data, HTTPURLResponse) {
		let (data, response) = try await executeRawMSURLSessionDataTask(with: request)
		guard let data, let response = response as? HTTPURLResponse else {
			throw MicrosoftGraphError.unexpectedResult
		}
		return (data, response)
	}

	private func executeMSURLSessionDataTaskWithErrorMapping(with request: NSMutableURLRequest) async throws -> Data {
		let (data, httpResponse) = try await executeMSURLSessionDataTask(with: request)
		guard httpResponse.statusCode == MSExpectedResponseCodes.OK.rawValue else {
			throw mapStatusCodeToError(httpResponse.statusCode)
		}
		return data
	}

	// MARK: - Helpers

	private func mapStatusCodeToError(_ statusCode: Int) -> Error {
		switch statusCode {
		case MSClientErrorCode.MSClientErrorCodeNotFound.rawValue:
			return CloudProviderError.itemNotFound
		case MSClientErrorCode.MSClientErrorCodeUnauthorized.rawValue:
			return CloudProviderError.unauthorized
		case MSClientErrorCode.MSClientErrorCodeInsufficientStorage.rawValue:
			return CloudProviderError.quotaInsufficient
		default:
			return MicrosoftGraphError.unexpectedHTTPStatusCode(code: statusCode)
		}
	}

	private func convertStandardError(_ error: Error) -> Error {
		if isCancellationError(error) {
			return CancellationError()
		}
		switch error {
		case MicrosoftGraphAuthenticationProviderError.accountNotFound:
			return CloudProviderError.unauthorized
		default:
			return error
		}
	}
}
