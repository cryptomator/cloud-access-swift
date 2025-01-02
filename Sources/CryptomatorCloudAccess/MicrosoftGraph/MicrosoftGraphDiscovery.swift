//
//  MicrosoftGraphDiscovery.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 02.12.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation
import MSGraphClientModels
import MSGraphClientSDK
import Promises

public class MicrosoftGraphDiscovery {
	private let client: MSHTTPClient

	public init(credential: MicrosoftGraphCredential) {
		self.client = MSClientFactory.createHTTPClient(with: credential.authProvider, andSessionConfiguration: .default)
	}

	public func fetchSharePointSite(for hostName: String, serverRelativePath: String) -> Promise<MicrosoftGraphSite> {
		let request: NSMutableURLRequest
		do {
			request = try sharePointSiteRequest(for: hostName, serverRelativePath: serverRelativePath)
		} catch {
			return Promise(error)
		}
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> MicrosoftGraphSite in
			let site = try MSGraphSite(data: data)
			return MicrosoftGraphSite(identifier: site.entityId, displayName: site.displayName)
		}
	}

	public func fetchSharePointDocumentLibraries(for siteIdentifier: String) -> Promise<[MicrosoftGraphDrive]> {
		let request: NSMutableURLRequest
		do {
			request = try sharePointDocumentLibrariesRequest(for: siteIdentifier)
		} catch {
			return Promise(error)
		}
		return executeMSURLSessionDataTaskWithErrorMapping(with: request).then { data -> [MicrosoftGraphDrive] in
			let collection = try MSCollection(data: data)
			return collection.value.compactMap { item in
				guard let drive = MSGraphDrive(dictionary: item as? [AnyHashable: Any]) else {
					return nil
				}
				return MicrosoftGraphDrive(identifier: drive.entityId, name: drive.name)
			}
		}
	}

	// MARK: - Requests

	func sharePointSiteRequest(for hostName: String, serverRelativePath: String) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(MSGraphBaseURL)/sites/\(hostName):/sites/\(serverRelativePath)") else {
			throw MicrosoftGraphError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		return request
	}

	func sharePointDocumentLibrariesRequest(for siteIdentifier: String) throws -> NSMutableURLRequest {
		guard let url = URL(string: "\(MSGraphBaseURL)/sites/\(siteIdentifier)/drives") else {
			throw MicrosoftGraphError.invalidURL
		}
		let request = NSMutableURLRequest(url: url)
		return request
	}

	// MARK: - Execution

	private func executeRawMSURLSessionDataTask(with request: NSMutableURLRequest) -> Promise<(Data?, URLResponse?)> {
		HTTPDebugLogger.logRequest(request as URLRequest)
		return Promise<(Data?, URLResponse?)> { fulfill, reject in
			let task = MSURLSessionDataTask(request: request, client: self.client) { data, response, error in
				if let response = response {
					HTTPDebugLogger.logResponse(response, with: data, or: nil)
				}
				if let error = error {
					reject(error)
				} else {
					fulfill((data, response))
				}
			}
			task?.execute()
		}.recover { error -> (Data?, URLResponse?) in
			throw self.convertStandardError(error)
		}
	}

	private func executeMSURLSessionDataTask(with request: NSMutableURLRequest) -> Promise<(Data, HTTPURLResponse)> {
		return executeRawMSURLSessionDataTask(with: request).then { data, response -> (Data, HTTPURLResponse) in
			guard let data = data, let response = response as? HTTPURLResponse else {
				throw MicrosoftGraphError.unexpectedResult
			}
			return (data, response)
		}
	}

	private func executeMSURLSessionDataTaskWithErrorMapping(with request: NSMutableURLRequest) -> Promise<Data> {
		return executeMSURLSessionDataTask(with: request).then { data, httpResponse -> Data in
			guard httpResponse.statusCode == MSExpectedResponseCodes.OK.rawValue else {
				throw (self.mapStatusCodeToError(httpResponse.statusCode))
			}
			return data
		}
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
		switch error {
		case MicrosoftGraphAuthenticationProviderError.accountNotFound, MicrosoftGraphAuthenticationProviderError.noAccounts:
			return CloudProviderError.unauthorized
		default:
			return error
		}
	}
}
