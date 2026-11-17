//
//  PCloudCredentialTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class PCloudCredentialTests {
		private static let userInfo = #"{"result":0,"email":"user@example.com","userid":7}"#
		/// The JSON in which the pCloud SDK stored its `OAuth.User`.
		private static let legacyUser = #"{"id":7,"token":"LEGACY","serverRegionId":2,"httpAPIHostName":"eapi.pcloud.com"}"#

		private let lockDirectoryURL: URL

		init() {
			URLProtocolMock.requestHandler = []
			self.lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		}

		deinit {
			guard FileManager.default.fileExists(atPath: lockDirectoryURL.path) else {
				return
			}
			removeItemRecordingFailure(at: lockDirectoryURL)
		}

		@Test
		func emptyUserIDThrows() throws {
			let setup = try PCloudSetup(appKey: "APP-KEY", oauth: .custom(storage: MemoryTokenStorage(buffer: TokenBuffer()), tokenLockDirectory: lockDirectoryURL))

			#expect(throws: PCloudCredentialError.missingUserID) { try PCloudCredential(userID: "", setup: setup) }
		}

		// MARK: - Login

		@Test
		func completeAuthenticationStoresTokenWithHostAndEmailUnderUserID() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo, onRequest: requests.record)]
			let buffer = TokenBuffer()
			let storage = MemoryTokenStorage(buffer: buffer)

			let credential = try await completeAuthentication(apiHostName: "EAPI.pcloud.com", storage: storage)

			#expect(credential.userID == "7")
			#expect([OAuthAccountKey(provider: .pCloud, account: "7")] == storage.keys)
			#expect(requests.requests.first?.url?.absoluteString == "https://eapi.pcloud.com/userinfo")
			#expect(requests.requests.first.map(URLProtocolMock.formParameters)?["access_token"] == "NEW-ACCESS")
			#expect(OAuthToken(accessToken: "NEW-ACCESS", refreshToken: nil, expiresAt: nil, username: "user@example.com", apiHost: "eapi.pcloud.com") == buffer.token)
			#expect(try credential.cachedUsername() == "user@example.com")
		}

		@Test
		func completeAuthenticationRejectsHostOutsidePCloudWithoutRequest() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo)]
			let buffer = TokenBuffer()

			for apiHostName in ["evil.example", "evilpcloud.com", "evil.com/.pcloud.com"] {
				let error = try await #require(throws: (any Error).self, "\(apiHostName)") { try await completeAuthentication(apiHostName: apiHostName, storage: MemoryTokenStorage(buffer: buffer)) }
				#expect((error as? URLError)?.code == .badURL, "\(apiHostName)")
			}
			#expect(URLProtocolMock.requestHandler.count == 1)
			#expect(buffer.data == nil)
		}

		/// The account request finishes even though the task was cancelled meanwhile, so the cancellation is checked before the token is stored.
		@Test
		func cancellationDuringAccountRequestStoresNothing() async throws {
			let accountRequested = TestSignal("account requested")
			let release = DispatchSemaphore(value: 0)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo, onRequest: { _ in
				accountRequested.fulfill()
				_ = release.wait(timeout: .now() + testWaitTimeout)
			})]
			let buffer = TokenBuffer()
			let storage = MemoryTokenStorage(buffer: buffer)

			let lockDirectoryURL = lockDirectoryURL
			let authentication = Task {
				try await PCloudCredentialTests.completeAuthentication(apiHostName: "eapi.pcloud.com", storage: storage, lockDirectoryURL: lockDirectoryURL)
			}
			await accountRequested.wait()
			authentication.cancel()
			release.signal()

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: authentication) }
			#expect(buffer.token == nil)
		}

		// MARK: - Stored Logins

		@Test
		func storedSDKLoginIsSentToItsHostAndKeepsItWithUsername() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo, onRequest: requests.record)]
			let buffer = TokenBuffer()
			buffer.data = Data(PCloudCredentialTests.legacyUser.utf8)
			let tokenSource = try makeTokenSource(buffer: buffer)
			let credential = PCloudCredential(userID: "7", tokenSource: tokenSource)

			#expect(try credential.cachedUsername() == nil)
			let username = try await credential.getUsername(client: .mocked(tokenSource: tokenSource))

			#expect(username == "user@example.com")
			#expect(requests.requests.first?.url?.absoluteString == "https://eapi.pcloud.com/userinfo")
			#expect(requests.requests.first.map(URLProtocolMock.formParameters)?["access_token"] == "LEGACY")
			#expect(OAuthToken(accessToken: "LEGACY", refreshToken: nil, expiresAt: nil, username: "user@example.com", apiHost: "eapi.pcloud.com") == buffer.token)
			#expect(try PCloudLogin(accessToken: "LEGACY", apiHost: "eapi.pcloud.com") == tokenSource.login())
		}

		@Test
		func storedTokenWithoutHostIsUnauthorized() throws {
			let buffer = TokenBuffer()
			buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: nil, expiresAt: nil))

			#expect(throws: CloudProviderError.unauthorized) { try makeTokenSource(buffer: buffer).login() }
		}

		@Test
		func deauthenticateDeletesLoginWithoutRequest() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo)]
			let buffer = TokenBuffer()
			buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: nil, expiresAt: nil, apiHost: "eapi.pcloud.com"))
			let credential = try PCloudCredential(userID: "7", tokenSource: makeTokenSource(buffer: buffer))

			try await credential.deauthenticate()

			#expect(buffer.data == nil)
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		/// pCloud tokens never expire, so a process must not keep using the token of a login that another process deleted.
		@Test
		func loginDeletedByAnotherProcessIsUnauthorized() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo), URLProtocolMock.handler(body: PCloudCredentialTests.userInfo)]
			let buffer = TokenBuffer()
			buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: nil, expiresAt: nil, apiHost: "eapi.pcloud.com"))
			let fileProviderTokenSource = try makeTokenSource(buffer: buffer, coordinator: OAuthTokenCoordinator())
			let appTokenSource = try makeTokenSource(buffer: buffer, coordinator: OAuthTokenCoordinator())
			let client = PCloudClient.mocked(tokenSource: fileProviderTokenSource)
			_ = try await fileProviderTokenSource.accessToken()
			_ = try await client.userInfoEmail()

			try await appTokenSource.deauthenticate()

			await #expect(throws: CloudProviderError.unauthorized) { try await client.userInfoEmail() }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func getUsernameThrowsAPIError() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.result(2009))]
			let credential = PCloudCredential(userID: "7", tokenSource: PCloudCredential.stubTokenSource)

			await #expect(throws: PCloudError.apiError(code: 2009, message: "Error 2009.")) { try await credential.getUsername(client: .mocked()) }
		}

		// MARK: - API Hosts

		@Test
		func acceptsAPIHostNames() {
			#expect(PCloudCredential.apiHost("api.pcloud.com") == "api.pcloud.com")
			#expect(PCloudCredential.apiHost("EAPI.PCLOUD.COM") == "eapi.pcloud.com")
		}

		@Test
		func hasStoredLoginOnlyWhileALoginWithAPIHostIsStored() throws {
			let buffer = TokenBuffer()
			let credential = try PCloudCredential(userID: "7", tokenSource: makeTokenSource(buffer: buffer))

			#expect(try !credential.hasStoredLogin())

			buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: nil, expiresAt: nil, username: nil))

			#expect(try !credential.hasStoredLogin())

			buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: nil, expiresAt: nil, username: nil, apiHost: "eapi.pcloud.com"))

			#expect(try credential.hasStoredLogin())
		}

		@Test
		func rejectsAPIHostNamesThatAreNoBareHostNamesOfPCloud() {
			for apiHostName in ["evil.com/.pcloud.com", "evil.com?.pcloud.com", "evil.com#.pcloud.com", "user@evil.com", "api.pcloud.com:8443", "api..pcloud.com", "", "[::1]", "api.pcloud.com.", "api pcloud.com", "äpi.pcloud.com", "evil.example", "evilpcloud.com", "1.2.3.4"] {
				#expect(PCloudCredential.apiHost(apiHostName) == nil, "\(apiHostName)")
			}
		}

		// MARK: - Helpers

		private func makeTokenSource(buffer: TokenBuffer, coordinator: OAuthTokenCoordinator = OAuthTokenCoordinator()) throws -> StoredOAuthTokenSource {
			return try PCloudCredential.makeTokenSource(userID: "7", oauth: .custom(storage: MemoryTokenStorage(buffer: buffer), tokenLockDirectory: lockDirectoryURL), assertion: ActivityScript().assertion, coordinator: coordinator)
		}

		private func completeAuthentication(apiHostName: String, storage: MemoryTokenStorage) async throws -> PCloudCredential {
			return try await PCloudCredentialTests.completeAuthentication(apiHostName: apiHostName, storage: storage, lockDirectoryURL: lockDirectoryURL)
		}

		private static func completeAuthentication(apiHostName: String, storage: MemoryTokenStorage, lockDirectoryURL: URL) async throws -> PCloudCredential {
			let oauth = try OAuthPersistence.custom(storage: storage, tokenLockDirectory: lockDirectoryURL)
			return try await PCloudCredential.completeAuthentication(accessToken: "NEW-ACCESS", userID: "7", apiHostName: apiHostName, makeClient: { PCloudClient.mocked(tokenSource: $0) }, makeTokenSource: { userID in
				PCloudCredential.makeTokenSource(userID: userID, oauth: oauth, assertion: ActivityScript().assertion, coordinator: OAuthTokenCoordinator())
			})
		}
	}
}
