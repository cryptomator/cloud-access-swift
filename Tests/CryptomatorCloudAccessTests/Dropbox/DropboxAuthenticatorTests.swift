//
//  DropboxAuthenticatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import AuthenticationServices
import CryptomatorCloudAccessTestSupport
import Foundation
import os
import Testing
@testable import CryptomatorCloudAccess
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	@MainActor
	final class DropboxAuthenticatorTests {
		private static let appKey = "appkey"
		private static let redirectURL = URL(string: "db-appkey://1/connect?state=STATE&oauth_code=CODE")!
		/// The example of RFC 7636, appendix B.
		private static let pkce = DropboxPKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", webState: "WEB-STATE")

		private var setup: DropboxSetup!

		// MARK: - Hand-Off

		@Test
		func awaitRedirectResumesWithRedirectURL() async throws {
			try setUpDropbox()
			let started = TestSignal("started")
			let redirect = Task {
				try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in started.fulfill() })
			}
			await started.wait()

			#expect(DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))

			let url = try await cancellingValue(of: redirect)
			#expect(DropboxAuthenticatorTests.redirectURL == url)
		}

		@Test
		func newerHandOffFailsOlderOneWhoseFailureLeavesNewerPending() async throws {
			try setUpDropbox()
			let failFirst = OSAllocatedUnfairLock<(@Sendable (Error) -> Void)?>(initialState: nil)
			let firstStarted = TestSignal("first started")
			let secondStarted = TestSignal("second started")
			let first = Task {
				try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { fail in
					failFirst.withLock { $0 = fail }
					firstStarted.fulfill()
				})
			}
			await firstStarted.wait()
			let second = Task {
				try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in secondStarted.fulfill() })
			}
			await secondStarted.wait()

			await #expect(throws: DropboxAuthenticatorError.authenticationFailed) { try await cancellingValue(of: first) }
			failFirst.withLock { $0 }?(CocoaError(.featureUnsupported))
			#expect(DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))
			let url = try await cancellingValue(of: second)
			#expect(DropboxAuthenticatorTests.redirectURL == url)
		}

		@Test
		func cancellationEndsHandOff() async throws {
			try setUpDropbox()
			let started = TestSignal("started")
			let redirect = Task {
				try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in started.fulfill() })
			}
			await started.wait()

			redirect.cancel()

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: redirect) }
			#expect(!DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))
		}

		@Test
		func cancelledTaskStartsNoHandOff() async throws {
			try setUpDropbox()
			let started = TestSignal("started")

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: cancelledTask {
					try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in started.fulfill() })
				})
			}
			await started.expectNoFulfillment(within: .seconds(0.1))
			#expect(!DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))
		}

		@Test
		func handleRedirectURLAcceptsOnlyRedirectsOfDropboxAppForPendingHandOff() async throws {
			try setUpDropbox()
			#expect(!DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))
			let started = TestSignal("started")
			let redirect = Task {
				try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in started.fulfill() })
			}
			await started.wait()

			let ignoredURLs = [
				"db-appkey://2/token?state=STATE&code=CODE",
				"db-other://1/connect?state=STATE&oauth_code=CODE",
				// `/connect` redirects without the pending hand-off's state, e.g., late ones of an earlier hand-off.
				"db-appkey://1/connect?state=OTHER&oauth_code=CODE",
				"db-appkey://1/connect?oauth_code=CODE"
			]
			for url in ignoredURLs {
				try #expect(!DropboxAuthenticator.handleRedirectURL(#require(URL(string: url)), setup: setup), "\(url)")
			}
			// The hand-off started with another app key.
			let otherSetup = DropboxSetup(appKey: "other", oauth: setup.oauth)
			try #expect(!DropboxAuthenticator.handleRedirectURL(#require(URL(string: "db-other://1/connect?state=STATE&oauth_code=CODE")), setup: otherSetup))

			#expect(DropboxAuthenticator.handleRedirectURL(DropboxAuthenticatorTests.redirectURL, setup: setup))
			let url = try await cancellingValue(of: redirect)
			#expect(DropboxAuthenticatorTests.redirectURL == url)
		}

		@Test
		func cancelRedirectWithoutStateCompletesHandOff() async throws {
			try setUpDropbox()
			let started = TestSignal("started")
			let redirect = Task {
				try await DropboxAuthenticator.awaitRedirect(appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE", startingWith: { _ in started.fulfill() })
			}
			await started.wait()
			let cancelURL = try #require(URL(string: "db-appkey://1/cancel"))

			#expect(DropboxAuthenticator.handleRedirectURL(cancelURL, setup: setup))

			let url = try await cancellingValue(of: redirect)
			#expect(cancelURL == url)
		}

		// MARK: - Callback URLs

		@Test
		func authorizationCodeFromCallbackURLs() throws {
			let callbackURLs = [
				"db-appkey://1/connect?state=STATE&oauth_code=CODE%2B1",
				"db-appkey://1/connect?state=STATE&oauth_token=oauth2code:&oauth_token_secret=CODE%2B1",
				"db-appkey://2/token?state=STATE&code=CODE%2B1"
			]
			for callbackURL in callbackURLs {
				#expect(try authorizationCode(fromCallbackURL: callbackURL) == "CODE+1", "\(callbackURL)")
			}
		}

		@Test
		func cancelledCallbackURLsAreUserCancelled() throws {
			let callbackURLs = [
				"db-appkey://1/cancel",
				"db-appkey://2/cancel",
				"db-appkey://1/other",
				"db-appkey://2/token?state=STATE&error=access_denied&error_description=The+user+chose+not+to+give+your+app+access"
			]
			for callbackURL in callbackURLs {
				let error = try #require(throws: (any Error).self, "\(callbackURL)") { try authorizationCode(fromCallbackURL: callbackURL) }
				#expect((error as? CocoaError)?.code == .userCancelled, "\(callbackURL)")
			}
		}

		@Test
		func rejectsInvalidCallbackURLs() {
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
				#expect(throws: DropboxAuthenticatorError.authenticationFailed, "\(callbackURL)") { try authorizationCode(fromCallbackURL: callbackURL) }
			}
		}

		@Test
		func testConvertLoginFlowError() {
			#expect((DropboxAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.canceledLogin)) as? CocoaError)?.code == .userCancelled)
			#expect((DropboxAuthenticator.convertLoginFlowError(ASWebAuthenticationSessionError(.presentationContextInvalid)) as? DropboxAuthenticatorError) == .authenticationFailed)
			#expect((DropboxAuthenticator.convertLoginFlowError(URLError(.timedOut)) as? URLError)?.code == .timedOut)
		}

		// MARK: - PKCE

		@Test
		func codeChallengeAndStatesOfPKCE() {
			let pkce = DropboxAuthenticatorTests.pkce

			#expect(pkce.codeChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
			#expect(pkce.dAuthState == "oauth2code:E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM:S256:offline:files.metadata.read files.metadata.write files.content.read files.content.write account_info.read")

			let random = DropboxPKCE.random()
			#expect(random.codeVerifier.count == 128)
			#expect(random.codeVerifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, "\(random.codeVerifier)")
			#expect(random.webState.count == 43)
			#expect(random.webState.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }, "\(random.webState)")
			#expect(random.codeVerifier != DropboxPKCE.random().codeVerifier)
		}

		@Test
		func dAuthURLCarriesPKCEParameters() throws {
			let url = try DropboxAuthenticator.dAuthURL(scheme: "dbapi-2", appKey: DropboxAuthenticatorTests.appKey, pkce: DropboxAuthenticatorTests.pkce)

			let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
			#expect(components.scheme == "dbapi-2")
			#expect(components.host == "1")
			#expect(components.path == "/connect")
			#expect([
				"k": "appkey",
				"s": "",
				"state": DropboxAuthenticatorTests.pkce.dAuthState,
				"extra_query_params": "code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&token_access_type=offline&response_type=code&scope=files.metadata.read files.metadata.write files.content.read files.content.write account_info.read"
			] == DropboxAuthenticatorTests.queryParameters(of: components))
		}

		@Test
		func authorizeURLCarriesPKCEParametersAndWebState() throws {
			let url = try DropboxAuthenticator.authorizeURL(appKey: DropboxAuthenticatorTests.appKey, pkce: DropboxAuthenticatorTests.pkce)

			let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
			#expect("https://www.dropbox.com/oauth2/authorize" == "\(components.scheme ?? "")://\(components.host ?? "")\(components.path)")
			#expect(DropboxAuthenticatorTests.queryParameters(of: components) == [
				"client_id": "appkey",
				"redirect_uri": "db-appkey://2/token",
				"response_type": "code",
				"token_access_type": "offline",
				"code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
				"code_challenge_method": "S256",
				"scope": "files.metadata.read files.metadata.write files.content.read files.content.write account_info.read",
				"state": "WEB-STATE",
				"disable_signup": "true"
			])
		}

		// MARK: - Helpers

		private func setUpDropbox() throws {
			let lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			setup = try DropboxSetup(appKey: DropboxAuthenticatorTests.appKey, oauth: .custom(storage: MemoryTokenStorage(buffer: TokenBuffer()), tokenLockDirectory: lockDirectoryURL))
		}

		private func authorizationCode(fromCallbackURL callbackURL: String) throws -> String {
			return try DropboxAuthenticator.authorizationCode(fromCallbackURL: #require(URL(string: callbackURL)), appKey: DropboxAuthenticatorTests.appKey, expectedState: "STATE")
		}

		private static func queryParameters(of components: URLComponents) -> [String: String] {
			return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
		}
	}
}
