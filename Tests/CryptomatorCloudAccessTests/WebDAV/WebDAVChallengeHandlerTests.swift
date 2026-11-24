//
//  WebDAVChallengeHandlerTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct WebDAVChallengeHandlerTests {
		/// A self-signed certificate for webdav.example.com.
		private let certificateData = Data(base64Encoded: "MIIBcDCCARagAwIBAgIULilZzK/EVqdYPl1QZan6gkotHE0wCgYIKoZIzj0EAwIwHTEbMBkGA1UEAwwSd2ViZGF2LmV4YW1wbGUuY29tMCAXDTI2MTAxODE1MjEzOFoYDzIxMjYwOTI0MTUyMTM4WjAdMRswGQYDVQQDDBJ3ZWJkYXYuZXhhbXBsZS5jb20wWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATPxiqoa1MNI0ZQ+uhxaj+bm81b7JLkExFkmPda/7F50QILMZmczaou6oGfJybc9hke4YthQShAYiKU4ax0yrTBozIwMDAdBgNVHQ4EFgQUUhdtBneMCq+1EABG5bsY/3xIk18wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiBwDWHRS73jFGIzaIsiQ5b+U+7uv88uT2HasToghSNZBwIhAPP8O6V5HvrO4HdGwL6lR/cCuzp/aQL18SVmagKYgDI3")!

		init() {
			URLProtocolMock.requestHandler = []
		}

		@Test
		func credentialMethodsGetCredentialOnFirstAttempt() {
			for authenticationMethod in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] {
				let decision = WebDAVChallengeHandler.decision(authenticationMethod: authenticationMethod, previousFailureCount: 0, serverTrust: nil, isDowngrade: false, credential: makeCredential(allowedCertificate: nil))
				#expect(decision.disposition == .useCredential, "\(authenticationMethod)")
				#expect(decision.credential?.user == "user", "\(authenticationMethod)")
				#expect(decision.credential?.password == "password", "\(authenticationMethod)")
				#expect(decision.failure == nil, "\(authenticationMethod)")
			}
		}

		@Test
		func credentialMethodsRecordUnauthorizedOnRetry() {
			for authenticationMethod in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] {
				let decision = WebDAVChallengeHandler.decision(authenticationMethod: authenticationMethod, previousFailureCount: 1, serverTrust: nil, isDowngrade: false, credential: makeCredential(allowedCertificate: nil))
				#expect(decision.disposition == .cancelAuthenticationChallenge, "\(authenticationMethod)")
				#expect((decision.failure as? WebDAVError) == .httpError(statusCode: 401), "\(authenticationMethod)")
			}
		}

		/// No password authentication runs over a downgraded connection, Digest included, which sends a response derived from the password.
		@Test
		func credentialMethodsAreRefusedAfterDowngrade() {
			for authenticationMethod in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodHTMLForm] {
				for previousFailureCount in [0, 1] {
					let decision = WebDAVChallengeHandler.decision(authenticationMethod: authenticationMethod, previousFailureCount: previousFailureCount, serverTrust: nil, isDowngrade: true, credential: makeCredential(allowedCertificate: nil))
					#expect(decision.disposition == .cancelAuthenticationChallenge, "\(authenticationMethod) \(previousFailureCount)")
					#expect(decision.credential == nil, "\(authenticationMethod) \(previousFailureCount)")
					#expect((decision.failure as? URLError)?.code == .appTransportSecurityRequiresSecureConnection, "\(authenticationMethod) \(previousFailureCount)")
				}
			}
		}

		@Test
		func onlyAnHTTPServerOfAnHTTPSTaskIsADowngrade() throws {
			let httpsURL = try #require(URL(string: "https://webdav.example.com/file.txt"))
			let uppercaseHTTPSURL = try #require(URL(string: "HTTPS://webdav.example.com/file.txt"))
			let httpURL = try #require(URL(string: "http://webdav.example.com/file.txt"))
			let httpSpace = URLProtectionSpace(host: "webdav.example.com", port: 80, protocol: NSURLProtectionSpaceHTTP, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
			let httpsSpace = URLProtectionSpace(host: "webdav.example.com", port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
			let proxySpace = URLProtectionSpace(proxyHost: "proxy.example.com", port: 8080, type: NSURLProtectionSpaceHTTPProxy, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

			#expect(WebDAVChallengeHandler.isDowngrade(of: httpSpace, originalURL: httpsURL))
			#expect(WebDAVChallengeHandler.isDowngrade(of: httpSpace, originalURL: uppercaseHTTPSURL))
			#expect(!WebDAVChallengeHandler.isDowngrade(of: httpsSpace, originalURL: httpsURL))
			#expect(!WebDAVChallengeHandler.isDowngrade(of: httpSpace, originalURL: httpURL))
			#expect(!WebDAVChallengeHandler.isDowngrade(of: proxySpace, originalURL: httpsURL))
			#expect(!WebDAVChallengeHandler.isDowngrade(of: httpSpace, originalURL: nil))
		}

		/// A session without a delegate follows the redirect from `https` to `http` as a background session does, so only the task's original request still shows that it started on `https`.
		@Test
		func passwordChallengeIsRefusedForATaskThatStartedOnHTTPS() async throws {
			let configuration = URLSessionConfiguration.default
			configuration.protocolClasses = [URLProtocolMock.self]
			let session = URLSession(configuration: configuration)
			defer {
				session.invalidateAndCancel()
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 302, headerFields: ["Location": "http://webdav.example.com/file.txt"]),
				URLProtocolMock.handler()
			]
			let completed = TestSignal("task completed")
			let task = try session.dataTask(with: #require(URL(string: "https://webdav.example.com/file.txt"))) { _, _, _ in
				completed.fulfill()
			}
			task.resume()
			await completed.wait()
			try #require(task.originalRequest?.url?.scheme == "https")
			try #require(task.currentRequest?.url?.scheme == "http")
			let protectionSpace = URLProtectionSpace(host: "webdav.example.com", port: 80, protocol: NSURLProtectionSpaceHTTP, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
			let challenge = URLAuthenticationChallenge(protectionSpace: protectionSpace, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: URLAuthenticationChallengeSenderMock())

			let decision = WebDAVChallengeHandler(credential: makeCredential(allowedCertificate: nil)).decision(for: challenge, task: task)

			#expect(decision.disposition == .cancelAuthenticationChallenge)
			#expect(decision.credential == nil)
			#expect((decision.failure as? URLError)?.code == .appTransportSecurityRequiresSecureConnection)
		}

		@Test
		func sessionWideMethodsGetDefaultHandling() {
			for authenticationMethod in [NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodClientCertificate] {
				let decision = WebDAVChallengeHandler.decision(authenticationMethod: authenticationMethod, previousFailureCount: 0, serverTrust: nil, isDowngrade: false, credential: makeCredential(allowedCertificate: certificateData))
				#expect(decision.disposition == .performDefaultHandling, "\(authenticationMethod)")
				#expect(decision.credential == nil, "\(authenticationMethod)")
				#expect(decision.failure == nil, "\(authenticationMethod)")
			}
		}

		@Test
		func serverTrustWithAllowedCertificateIsTrusted() throws {
			let decision = try WebDAVChallengeHandler.decision(authenticationMethod: NSURLAuthenticationMethodServerTrust, previousFailureCount: 0, serverTrust: makeTrust(), isDowngrade: false, credential: makeCredential(allowedCertificate: certificateData))
			#expect(decision.disposition == .useCredential)
			#expect(decision.credential != nil)
			#expect(decision.failure == nil)
		}

		@Test
		func serverTrustWithOtherCertificateGetsDefaultHandling() throws {
			let decision = try WebDAVChallengeHandler.decision(authenticationMethod: NSURLAuthenticationMethodServerTrust, previousFailureCount: 0, serverTrust: makeTrust(), isDowngrade: false, credential: makeCredential(allowedCertificate: Data("other".utf8)))
			#expect(decision.disposition == .performDefaultHandling)
			#expect(decision.credential == nil)
			#expect(decision.failure == nil)
		}

		@Test
		func serverTrustRetryIsCancelledWithoutFailure() throws {
			let decision = try WebDAVChallengeHandler.decision(authenticationMethod: NSURLAuthenticationMethodServerTrust, previousFailureCount: 1, serverTrust: makeTrust(), isDowngrade: false, credential: makeCredential(allowedCertificate: certificateData))
			#expect(decision.disposition == .cancelAuthenticationChallenge)
			#expect(decision.credential == nil)
			#expect(decision.failure == nil)
		}

		// MARK: - Helpers

		private func makeCredential(allowedCertificate: Data?) -> WebDAVCredential {
			return WebDAVCredential(baseURL: URL(string: "https://webdav.example.com/")!, username: "user", password: "password", allowedCertificate: allowedCertificate)
		}

		private func makeTrust() throws -> SecTrust {
			let certificate = try #require(SecCertificateCreateWithData(nil, certificateData as CFData))
			var trust: SecTrust?
			#expect(errSecSuccess == SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust))
			return try #require(trust)
		}
	}
}
