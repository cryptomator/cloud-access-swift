//
//  MSClientFactory+UnauthenticatedClient.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 12.09.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import MSGraphClientSDK

extension MSClientFactory {
	static func createUnauthenticatedHTTPClient(with urlSessionConfiguration: URLSessionConfiguration) -> MSHTTPClient {
		let redirectHandler = MSMiddlewareFactory.createMiddleware(.redirect) as MSGraphMiddleware
		let retryHandler = MSMiddlewareFactory.createMiddleware(.retry) as MSGraphMiddleware
		let sessionManager = MSURLSessionManager(sessionConfiguration: urlSessionConfiguration)
		redirectHandler.setNext(retryHandler)
		retryHandler.setNext(sessionManager)
		return MSClientFactory.createHTTPClient(with: redirectHandler)
	}
}
