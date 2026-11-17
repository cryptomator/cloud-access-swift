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

		@Test
		func credentialMethodsGetCredentialOnFirstAttempt() {
			for authenticationMethod in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] {
				let decision = WebDAVChallengeHandler.decision(authenticationMethod: authenticationMethod, previousFailureCount: 0, serverTrust: nil, credential: makeCredential(allowedCertificate: nil))
				#expect(decision.disposition == .useCredential, "\(authenticationMethod)")
				#expect(decision.credential?.user == "user", "\(authenticationMethod)")
				#expect(decision.credential?.password == "password", "\(authenticationMethod)")
				#expect(decision.failure == nil, "\(authenticationMethod)")
			}
		}

		@Test
		func credentialMethodsRecordUnauthorizedOnRetry() {
			for authenticationMethod in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] {
				let decision = WebDAVChallengeHandler.decision(authenticationMethod: authenticationMethod, previousFailureCount: 1, serverTrust: nil, credential: makeCredential(allowedCertificate: nil))
				#expect(decision.disposition == .cancelAuthenticationChallenge, "\(authenticationMethod)")
				#expect((decision.failure as? WebDAVError) == .httpError(statusCode: 401), "\(authenticationMethod)")
			}
		}

		@Test
		func sessionWideMethodsGetDefaultHandling() {
			for authenticationMethod in [NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodClientCertificate] {
				let decision = WebDAVChallengeHandler.decision(authenticationMethod: authenticationMethod, previousFailureCount: 0, serverTrust: nil, credential: makeCredential(allowedCertificate: certificateData))
				#expect(decision.disposition == .performDefaultHandling, "\(authenticationMethod)")
				#expect(decision.credential == nil, "\(authenticationMethod)")
				#expect(decision.failure == nil, "\(authenticationMethod)")
			}
		}

		@Test
		func serverTrustWithAllowedCertificateIsTrusted() throws {
			let decision = try WebDAVChallengeHandler.decision(authenticationMethod: NSURLAuthenticationMethodServerTrust, previousFailureCount: 0, serverTrust: makeTrust(), credential: makeCredential(allowedCertificate: certificateData))
			#expect(decision.disposition == .useCredential)
			#expect(decision.credential != nil)
			#expect(decision.failure == nil)
		}

		@Test
		func serverTrustWithOtherCertificateGetsDefaultHandling() throws {
			let decision = try WebDAVChallengeHandler.decision(authenticationMethod: NSURLAuthenticationMethodServerTrust, previousFailureCount: 0, serverTrust: makeTrust(), credential: makeCredential(allowedCertificate: Data("other".utf8)))
			#expect(decision.disposition == .performDefaultHandling)
			#expect(decision.credential == nil)
			#expect(decision.failure == nil)
		}

		@Test
		func serverTrustRetryIsCancelledWithoutFailure() throws {
			let decision = try WebDAVChallengeHandler.decision(authenticationMethod: NSURLAuthenticationMethodServerTrust, previousFailureCount: 1, serverTrust: makeTrust(), credential: makeCredential(allowedCertificate: certificateData))
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
