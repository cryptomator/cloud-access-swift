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
		guard let handler = URLProtocolMock.requestHandlerStorage.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
			client?.urlProtocol(self, didFailWithError: URLProtocolMockError.unexpectedRequest)
			return
		}
		do {
			let (response, data) = try handler(request)
			if (300 ... 399).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"), let redirectURL = URL(string: location, relativeTo: request.url) {
				var redirectRequest = request
				redirectRequest.url = redirectURL
				client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: response)
				return
			}
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

	/// Returns a configuration whose requests this mock answers and that sends the marker in the `X-Session` header, so that a test can tell which session sent a request.
	static func configuration(marker: String) -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.default
		configuration.protocolClasses = [URLProtocolMock.self]
		configuration.httpAdditionalHeaders = ["X-Session": marker]
		return configuration
	}
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
		guard let challengeSettings = URLProtocolAuthenticationMock.authenticationChallengesStorage.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
			client?.urlProtocol(self, didFailWithError: URLProtocolMockError.unexpectedRequest)
			return
		}
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
		/// A response whose body is delivered in several chunks, with a pause in between. URLSession then passes each chunk of about 1 KiB or more to the delegate in a separate call, and may still combine smaller ones. This is observed, not documented.
		case chunkedResponse(HTTPURLResponse, [Data])
		case failure(Error)
		case authChallenge(URLAuthenticationChallengeMock)
	}

	private static let stepsStorage = OSAllocatedUnfairLock(initialState: [Step]())

	static var steps: [Step] {
		get { stepsStorage.withLock { $0 } }
		set { stepsStorage.withLock { $0 = newValue } }
	}

	override func startLoading() {
		guard let step = URLProtocolSequenceMock.stepsStorage.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
			client?.urlProtocol(self, didFailWithError: URLProtocolMockError.unexpectedRequest)
			return
		}
		switch step {
		case let .response(response, data):
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			if let data {
				client?.urlProtocol(self, didLoad: data)
			}
			client?.urlProtocolDidFinishLoading(self)
		case let .chunkedResponse(response, chunks):
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			for (index, chunk) in chunks.enumerated() {
				if index > 0 {
					// Without the pause, URLSession combines chunks loaded back to back.
					Thread.sleep(forTimeInterval: 0.05)
				}
				client?.urlProtocol(self, didLoad: chunk)
			}
			client?.urlProtocolDidFinishLoading(self)
		case let .failure(error):
			client?.urlProtocol(self, didFailWithError: error)
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
