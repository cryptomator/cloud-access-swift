//
//  DropboxAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
import os
import XCTest
@testable import CryptomatorCloudAccess
#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif

@MainActor
class DropboxAuthenticatorTests: XCTestCase {
	private static let appKey = "appkey"
	private static let redirectURL = URL(string: "db-appkey://1/connect?state=STATE&oauth_code=CODE")!
	/// The example of RFC 7636, appendix B.
	private static let pkce = DropboxPKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", webState: "WEB-STATE")

	private var setup: DropboxSetup!

	// MARK: - Hand-Off

	func testAwaitRedirectResumesWithRedirectURL() async throws {
		try setUpDropbox()
		let started = XCTestExpectation(description: "started")
		let redirect = Task {
			try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in started.fulfill() })
		}
		await fulfillment(of: [started], timeout: testWaitTimeout)

		XCTAssertTrue(DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))

		let url = try await value(of: redirect)
		XCTAssertEqual(DropboxAuthenticatorTests.redirectURL, url)
	}

	func testNewerHandOffFailsOlderOneWhoseFailureLeavesNewerPending() async throws {
		try setUpDropbox()
		let failFirst = OSAllocatedUnfairLock<(@Sendable (Error) -> Void)?>(initialState: nil)
		let firstStarted = XCTestExpectation(description: "first started")
		let secondStarted = XCTestExpectation(description: "second started")
		let first = Task {
			try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { fail in
				failFirst.withLock { $0 = fail }
				firstStarted.fulfill()
			})
		}
		await fulfillment(of: [firstStarted], timeout: testWaitTimeout)
		let second = Task {
			try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in secondStarted.fulfill() })
		}
		await fulfillment(of: [secondStarted], timeout: testWaitTimeout)

		await XCTAssertThrowsErrorAsync(try await value(of: first)) { error in
			XCTAssertEqual(.authenticationFailed, error as? DropboxAuthenticatorError)
		}
		failFirst.withLock { $0 }?(CocoaError(.featureUnsupported))
		XCTAssertTrue(DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))
		let url = try await value(of: second)
		XCTAssertEqual(DropboxAuthenticatorTests.redirectURL, url)
	}

	func testCancellationEndsHandOff() async throws {
		try setUpDropbox()
		let started = XCTestExpectation(description: "started")
		let redirect = Task {
			try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in started.fulfill() })
		}
		await fulfillment(of: [started], timeout: testWaitTimeout)

		redirect.cancel()

		await XCTAssertThrowsErrorAsync(try await value(of: redirect)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertFalse(DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))
	}

	func testCancelledTaskStartsNoHandOff() async throws {
		try setUpDropbox()
		let started = XCTestExpectation(description: "started")
		started.isInverted = true

		await XCTAssertThrowsErrorAsync(try await value(of: cancelledTask {
			try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in started.fulfill() })
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		await fulfillment(of: [started], timeout: 0.1)
		XCTAssertFalse(DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))
	}

	func testHandleRedirectURLAcceptsOnlyRedirectsOfDropboxAppForPendingHandOff() async throws {
		try setUpDropbox()
		XCTAssertFalse(DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))
		let started = XCTestExpectation(description: "started")
		let redirect = Task {
			try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in started.fulfill() })
		}
		await fulfillment(of: [started], timeout: testWaitTimeout)

		let ignoredURLs = [
			"db-appkey://2/token?state=STATE&code=CODE",
			"db-other://1/connect?state=STATE&oauth_code=CODE",
			// `/connect` redirects without the pending hand-off's state, e.g., late ones of an earlier hand-off.
			"db-appkey://1/connect?state=OTHER&oauth_code=CODE",
			"db-appkey://1/connect?oauth_code=CODE"
		]
		for url in ignoredURLs {
			try XCTAssertFalse(DropboxAuthenticator.handleRedirectURL(XCTUnwrap(URL(string: url)), setup: setup), url)
		}
		// The hand-off started with another app key.
		let otherSetup = DropboxSetup(appKey: "other", oauth: setup.oauth)
		try XCTAssertFalse(DropboxAuthenticator.handleRedirectURL(XCTUnwrap(URL(string: "db-other://1/connect?state=STATE&oauth_code=CODE")), setup: otherSetup))

		XCTAssertTrue(DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))
		let url = try await value(of: redirect)
		XCTAssertEqual(DropboxAuthenticatorTests.redirectURL, url)
	}

	func testCancelRedirectWithoutStateCompletesHandOff() async throws {
		try setUpDropbox()
		let started = XCTestExpectation(description: "started")
		let redirect = Task {
			try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in started.fulfill() })
		}
		await fulfillment(of: [started], timeout: testWaitTimeout)
		let cancelURL = try XCTUnwrap(URL(string: "db-appkey://1/cancel"))

		XCTAssertTrue(DropboxAuthenticator.handleRedirectURL(cancelURL, setup: setup))

		let url = try await value(of: redirect)
		XCTAssertEqual(cancelURL, url)
	}

	// MARK: - Callback URLs

	func testAuthorizationCodeFromCallbackURLs() throws {
		let callbackURLs = [
			"db-appkey://1/connect?state=STATE&oauth_code=CODE%2B1",
			"db-appkey://1/connect?state=STATE&oauth_token=oauth2code:&oauth_token_secret=CODE%2B1",
			"db-appkey://2/token?state=STATE&code=CODE%2B1"
		]
		for callbackURL in callbackURLs {
			XCTAssertEqual("CODE+1", try authorizationCode(fromCallbackURL: callbackURL), callbackURL)
		}
	}

	func testCancelledCallbackURLsAreUserCancelled() {
		let callbackURLs = [
			"db-appkey://1/cancel",
			"db-appkey://2/cancel",
			"db-appkey://1/other",
			"db-appkey://2/token?state=STATE&error=access_denied&error_description=The+user+chose+not+to+give+your+app+access"
		]
		for callbackURL in callbackURLs {
			XCTAssertThrowsError(try authorizationCode(fromCallbackURL: callbackURL), callbackURL) { error in
				XCTAssertEqual(.userCancelled, (error as? CocoaError)?.code, callbackURL)
			}
		}
	}

	func testRejectsInvalidCallbackURLs() {
		let callbackURLs = [
			"db-other://1/connect?state=STATE&oauth_code=CODE",
			"db-appkey://3/connect?state=STATE&oauth_code=CODE",
			"db-appkey://1/connect?state=OTHER&oauth_code=CODE",
			"db-appkey://2/token?state=OTHER&code=CODE",
			"db-appkey://2/token?code=CODE",
			"db-appkey://2/token?state=STATE&error=server_error",
			"db-appkey://1/connect?state=STATE&oauth_token=other&oauth_token_secret=CODE",
			"db-appkey://2/token?state=STATE&code="
		]
		for callbackURL in callbackURLs {
			XCTAssertThrowsError(try authorizationCode(fromCallbackURL: callbackURL), callbackURL) { error in
				XCTAssertEqual(.authenticationFailed, error as? DropboxAuthenticatorError, callbackURL)
			}
		}
	}

	func testConvertLoginFlowError() {
		XCTAssertEqual(.userCancelled, (DropboxAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.canceledLogin)) as? CocoaError)?.code)
		XCTAssertEqual(.authenticationFailed, DropboxAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.presentationContextInvalid)) as? DropboxAuthenticatorError)
	}

	// MARK: - PKCE

	func testCodeChallengeAndStatesOfPKCE() {
		let pkce = DropboxAuthenticatorTests.pkce

		XCTAssertEqual("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", pkce.codeChallenge)
		XCTAssertEqual("oauth2code:E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM:S256:offline:files.metadata.read files.metadata.write files.content.read files.content.write account_info.read", pkce.dAuthState)

		let random = DropboxPKCE.random()
		XCTAssertEqual(128, random.codeVerifier.count)
		XCTAssertTrue(random.codeVerifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, random.codeVerifier)
		XCTAssertEqual(43, random.webState.count)
		XCTAssertTrue(random.webState.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }, random.webState)
		XCTAssertNotEqual(random.codeVerifier, DropboxPKCE.random().codeVerifier)
	}

	func testDAuthURLCarriesPKCEParameters() throws {
		let url = try DropboxAuthenticator.dAuthURL(scheme: "dbapi-2", appKey: DropboxAuthenticatorTests.appKey, pkce: DropboxAuthenticatorTests.pkce)

		let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
		XCTAssertEqual("dbapi-2", components.scheme)
		XCTAssertEqual("1", components.host)
		XCTAssertEqual("/connect", components.path)
		XCTAssertEqual([
			"k": "appkey",
			"s": "",
			"state": DropboxAuthenticatorTests.pkce.dAuthState,
			"extra_query_params": "code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&token_access_type=offline&response_type=code&scope=files.metadata.read files.metadata.write files.content.read files.content.write account_info.read"
		], DropboxAuthenticatorTests.queryParameters(of: components))
	}

	func testAuthorizeURLCarriesPKCEParametersAndWebState() throws {
		let url = try DropboxAuthenticator.authorizeURL(appKey: DropboxAuthenticatorTests.appKey, pkce: DropboxAuthenticatorTests.pkce)

		let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
		XCTAssertEqual("https://www.dropbox.com/oauth2/authorize", "\(components.scheme ?? "")://\(components.host ?? "")\(components.path)")
		XCTAssertEqual([
			"client_id": "appkey",
			"redirect_uri": "db-appkey://2/token",
			"response_type": "code",
			"token_access_type": "offline",
			"code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
			"code_challenge_method": "S256",
			"scope": "files.metadata.read files.metadata.write files.content.read files.content.write account_info.read",
			"state": "WEB-STATE",
			"disable_signup": "true"
		], DropboxAuthenticatorTests.queryParameters(of: components))
	}

	// MARK: - Helpers

	private func setUpDropbox() throws {
		let lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		setup = try DropboxSetup(appKey: DropboxAuthenticatorTests.appKey, oauth: .custom(storage: MemoryTokenStorage(buffer: TokenBuffer()), tokenLockDirectory: lockDirectoryURL))
	}

	private func authorizationCode(fromCallbackURL callbackURL: String) throws -> String {
		return try DropboxAuthenticator.authorizationCode(fromCallbackURL: XCTUnwrap(URL(string: callbackURL)), appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE")
	}

	private static func queryParameters(of components: URLComponents) -> [String: String] {
		return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
	}
}
