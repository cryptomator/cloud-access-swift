//
//  URLProtocolMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 08.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

enum URLProtocolMockError: Error {
	case unexpectedRequest
	case simulatedTransportFailure
}

class URLProtocolMock: URLProtocol {
	private static let requestHandlerStorage = OSAllocatedUnfairLock(initialState: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)]())

	static var requestHandler: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
		get { requestHandlerStorage.withLock { $0 } }
		set { requestHandlerStorage.withLock { $0 = newValue } }
	}

	override func startLoading() {
		let handler = URLProtocolMock.requestHandlerStorage.withLock { $0.removeFirst() }
		do {
			let (response, data) = try handler(request)
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			if let data {
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

/// The sender of the challenges that the mocks emit. A `URLProtocol` can't be the sender itself, because the sender has to be `Sendable`.
final class URLAuthenticationChallengeSenderMock: NSObject, URLAuthenticationChallengeSender {
	func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}

	func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}

	func cancel(_ challenge: URLAuthenticationChallenge) {}
}

class URLProtocolAuthenticationMock: URLProtocol {
	private static let authenticationChallengesStorage = OSAllocatedUnfairLock(initialState: [URLAuthenticationChallengeMock]())

	static var authenticationChallenges: [URLAuthenticationChallengeMock] {
		get { authenticationChallengesStorage.withLock { $0 } }
		set { authenticationChallengesStorage.withLock { $0 = newValue } }
	}

	override func startLoading() {
		let challengeSettings = URLProtocolAuthenticationMock.authenticationChallengesStorage.withLock { $0.removeFirst() }
		let protectionSpace = URLProtectionSpace(host: "", port: 443, protocol: nil, realm: nil, authenticationMethod: nil)
		let challenge = URLAuthenticationChallenge(protectionSpace: protectionSpace, proposedCredential: nil, previousFailureCount: challengeSettings.previousFailureCount, failureResponse: challengeSettings.failureResponse, error: nil, sender: URLAuthenticationChallengeSenderMock())
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

/// Test-only `URLProtocol` that emits a queued sequence of either HTTP responses or auth challenges
/// in order. Used to target an auth challenge at a specific request (e.g. the transfer task) while
/// letting earlier requests (e.g. the preflight `PROPFIND`) resolve normally.
class URLProtocolSequenceMock: URLProtocol {
	enum Step {
		case response(HTTPURLResponse, Data?)
		case authChallenge(URLAuthenticationChallengeMock)
	}

	private static let stepsStorage = OSAllocatedUnfairLock(initialState: [Step]())

	static var steps: [Step] {
		get { stepsStorage.withLock { $0 } }
		set { stepsStorage.withLock { $0 = newValue } }
	}

	override func startLoading() {
		let step = URLProtocolSequenceMock.stepsStorage.withLock { $0.removeFirst() }
		switch step {
		case let .response(response, data):
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			if let data {
				client?.urlProtocol(self, didLoad: data)
			}
			client?.urlProtocolDidFinishLoading(self)
		case let .authChallenge(settings):
			let protectionSpace = URLProtectionSpace(host: "", port: 443, protocol: nil, realm: nil, authenticationMethod: nil)
			let challenge = URLAuthenticationChallenge(protectionSpace: protectionSpace, proposedCredential: nil, previousFailureCount: settings.previousFailureCount, failureResponse: settings.failureResponse, error: nil, sender: URLAuthenticationChallengeSenderMock())
			client?.urlProtocol(self, didReceive: challenge)
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
