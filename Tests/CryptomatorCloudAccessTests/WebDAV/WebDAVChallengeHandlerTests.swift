//
//  WebDAVChallengeHandlerTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class WebDAVChallengeHandlerTests: XCTestCase {
	/// A self-signed certificate for webdav.example.com.
	private let certificateData = Data(base64Encoded: "MIIBcDCCARagAwIBAgIULilZzK/EVqdYPl1QZan6gkotHE0wCgYIKoZIzj0EAwIwHTEbMBkGA1UEAwwSd2ViZGF2LmV4YW1wbGUuY29tMCAXDTI2MTAxODE1MjEzOFoYDzIxMjYwOTI0MTUyMTM4WjAdMRswGQYDVQQDDBJ3ZWJkYXYuZXhhbXBsZS5jb20wWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATPxiqoa1MNI0ZQ+uhxaj+bm81b7JLkExFkmPda/7F50QILMZmczaou6oGfJybc9hke4YthQShAYiKU4ax0yrTBozIwMDAdBgNVHQ4EFgQUUhdtBneMCq+1EABG5bsY/3xIk18wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiBwDWHRS73jFGIzaIsiQ5b+U+7uv88uT2HasToghSNZBwIhAPP8O6V5HvrO4HdGwL6lR/cCuzp/aQL18SVmagKYgDI3")!

	func testCredentialMethodsGetCredentialOnFirstAttempt() {
		for authenticationMethod in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] {
			let decision = WebDAVChallengeHandler.decision(authenticationMethod: authenticationMethod, previousFailureCount: 0, serverTrust: nil, credential: makeCredential(allowedCertificate: nil))
			XCTAssertEqual(.useCredential, decision.disposition, authenticationMethod)
			XCTAssertEqual("user", decision.credential?.user, authenticationMethod)
			XCTAssertEqual("password", decision.credential?.password, authenticationMethod)
			XCTAssertNil(decision.failure, authenticationMethod)
		}
	}

	func testCredentialMethodsRecordUnauthorizedOnRetry() {
		for authenticationMethod in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] {
			let decision = WebDAVChallengeHandler.decision(authenticationMethod: authenticationMethod, previousFailureCount: 1, serverTrust: nil, credential: makeCredential(allowedCertificate: nil))
			XCTAssertEqual(.cancelAuthenticationChallenge, decision.disposition, authenticationMethod)
			guard case URLSessionError.httpError(nil, statusCode: 401)? = decision.failure else {
				XCTFail("\(authenticationMethod) recorded \(String(describing: decision.failure))")
				continue
			}
		}
	}

	func testSessionWideMethodsGetDefaultHandling() {
		for authenticationMethod in [NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodClientCertificate] {
			let decision = WebDAVChallengeHandler.decision(authenticationMethod: authenticationMethod, previousFailureCount: 0, serverTrust: nil, credential: makeCredential(allowedCertificate: certificateData))
			XCTAssertEqual(.performDefaultHandling, decision.disposition, authenticationMethod)
			XCTAssertNil(decision.credential, authenticationMethod)
			XCTAssertNil(decision.failure, authenticationMethod)
		}
	}

	func testServerTrustWithAllowedCertificateIsTrusted() throws {
		let decision = try WebDAVChallengeHandler.decision(authenticationMethod: NSURLAuthenticationMethodServerTrust, previousFailureCount: 0, serverTrust: makeTrust(), credential: makeCredential(allowedCertificate: certificateData))
		XCTAssertEqual(.useCredential, decision.disposition)
		XCTAssertNotNil(decision.credential)
		XCTAssertNil(decision.failure)
	}

	func testServerTrustWithOtherCertificateGetsDefaultHandling() throws {
		let decision = try WebDAVChallengeHandler.decision(authenticationMethod: NSURLAuthenticationMethodServerTrust, previousFailureCount: 0, serverTrust: makeTrust(), credential: makeCredential(allowedCertificate: Data("other".utf8)))
		XCTAssertEqual(.performDefaultHandling, decision.disposition)
		XCTAssertNil(decision.credential)
		XCTAssertNil(decision.failure)
	}

	func testServerTrustRetryIsCancelledWithoutFailure() throws {
		let decision = try WebDAVChallengeHandler.decision(authenticationMethod: NSURLAuthenticationMethodServerTrust, previousFailureCount: 1, serverTrust: makeTrust(), credential: makeCredential(allowedCertificate: certificateData))
		XCTAssertEqual(.cancelAuthenticationChallenge, decision.disposition)
		XCTAssertNil(decision.credential)
		XCTAssertNil(decision.failure)
	}

	// MARK: - Helpers

	private func makeCredential(allowedCertificate: Data?) -> WebDAVCredential {
		return WebDAVCredential(baseURL: URL(string: "https://webdav.example.com/")!, username: "user", password: "password", allowedCertificate: allowedCertificate)
	}

	private func makeTrust() throws -> SecTrust {
		let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certificateData as CFData))
		var trust: SecTrust?
		XCTAssertEqual(errSecSuccess, SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust))
		return try XCTUnwrap(trust)
	}
}
