//
//  SharePointDiscovery.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 02.12.24.
//

import Foundation
import MSGraphClientSDK
import Promises

class SharePointDiscovery {
	private let client: MSHTTPClient
	init(credential: SharePointCredential) {
		self.client = MSClientFactory.createHTTPClient(
			with: credential.authProvider, andSessionConfiguration: .default
		)
	}

	func fetchSharePointSiteID(for hostname: String, serverRelativePath: String) -> Promise<String> {
		let url = "\(MSGraphBaseURL)/sites/root:/sites/\(serverRelativePath)"
		return executeRequest(with: url).then { data in
			let site = try JSONDecoder().decode(SharePointSite.self, from: data)
			return site.id
		}
	}

	func fetchSharePointDocumentLibraries(for siteID: String) -> Promise<[SharePointDocumentLibrary]> {
		let url = "\(MSGraphBaseURL)/sites/\(siteID)/drives"
		return executeRequest(with: url).then { data in
			let libraries = try JSONDecoder().decode([SharePointDocumentLibrary].self, from: data)
			return libraries
		}
	}

	private func executeRequest(with url: String) -> Promise<Data> {
		return Promise { fulfill, reject in
			guard let requestURL = URL(string: url) else {
				reject(MicrosoftGraphError.invalidURL)
				return
			}
			let request = NSMutableURLRequest(url: requestURL)
			let task = MSURLSessionDataTask(request: request, client: self.client) {
				data, _, error in
				if let error = error {
					reject(error)
				} else if let data = data {
					fulfill(data)
				} else {
					reject(CloudProviderError.unauthorized)
				}
			}
			task?.execute()
		}
	}
}
