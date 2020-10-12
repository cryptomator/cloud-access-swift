//
//  MockURLProtocol.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 08.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
enum MockURLProtocolError: Error {
	case unexpectedRequest
}

class MockURLProtocol: URLProtocol {
	static var requestHandler = [(URLRequest) throws -> (HTTPURLResponse, Data?)]()

	override func startLoading() {
		let handler = MockURLProtocol.requestHandler.removeFirst()
		do {
			let (response, data) = try handler(request)
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			if let data = data {
				client?.urlProtocol(self, didLoad: data)
			} else {
				print("no data")
			}
			client?.urlProtocolDidFinishLoading(self)
		} catch {
			client?.urlProtocol(self, didFailWithError: error)
		}
	}

	override class func canInit(with request: URLRequest) -> Bool {
		return true
	}

	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
		return request
	}

	override func stopLoading() {}
}
