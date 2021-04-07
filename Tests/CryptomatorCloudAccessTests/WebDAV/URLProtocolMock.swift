//
//  URLProtocolMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 08.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

enum MockURLProtocolError: Error {
	case unexpectedRequest
}

class URLProtocolMock: URLProtocol {
	static var requestHandler = [(URLRequest) throws -> (HTTPURLResponse, Data?)]()

	override func startLoading() {
		let handler = URLProtocolMock.requestHandler.removeFirst()
		do {
			let (response, data) = try handler(request)
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			if let data = data {
				client?.urlProtocol(self, didLoad: data)
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

struct URLAuthenticationChallengeMock {
	let previousFailureCount: Int
	let failureResponse: URLResponse
}

class URLProtocolAuthenticationMock: URLProtocol, URLAuthenticationChallengeSender {
	func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}

	func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}

	func cancel(_ challenge: URLAuthenticationChallenge) {}

	static var authenticationChallenges = [URLAuthenticationChallengeMock]()

	override func startLoading() {
		let challengeSettings = URLProtocolAuthenticationMock.authenticationChallenges.removeFirst()
		let protectionSpace = URLProtectionSpace(host: "", port: 443, protocol: nil, realm: nil, authenticationMethod: nil)
		let challenge = URLAuthenticationChallenge(protectionSpace: protectionSpace, proposedCredential: nil, previousFailureCount: challengeSettings.previousFailureCount, failureResponse: challengeSettings.failureResponse, error: nil, sender: self)
		client?.urlProtocol(self, didReceive: challenge)
	}

	override class func canInit(with request: URLRequest) -> Bool {
		return true
	}

	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
		return request
	}

	override func stopLoading() {}
}
