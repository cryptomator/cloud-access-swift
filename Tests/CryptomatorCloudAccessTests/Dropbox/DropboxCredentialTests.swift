//
//  DropboxCredentialTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class DropboxCredentialTests {
		private static let exchangeResponse = #"{"access_token":"NEW-ACCESS","expires_in":14400,"token_type":"bearer","refresh_token":"NEW-REFRESH","uid":"12345","account_id":"dbid:ACCOUNT"}"#
		private static let account = #"{"account_id":"dbid:ACCOUNT","email":"user@example.com"}"#
		private static let previousLogin = OAuthToken(accessToken: "PREVIOUS", refreshToken: "PREVIOUS-REFRESH", expiresAt: nil, username: "previous@example.com")

		private var lockDirectoryURL: URL

		init() {
			URLProtocolMock.requestHandler = []
			self.lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		}

		deinit {
			if FileManager.default.fileExists(atPath: lockDirectoryURL.path) {
				removeItemRecordingFailure(at: lockDirectoryURL)
			}
		}

		@Test
		func emptyUserIDThrows() throws {
			let setup = try DropboxSetup(appKey: "appkey", oauth: .custom(storage: MemoryTokenStorage(buffer: TokenBuffer()), tokenLockDirectory: lockDirectoryURL))

			#expect(throws: DropboxCredentialError.missingUserID) { try DropboxCredential(userID: "", setup: setup) }
		}

		// MARK: - Login

		@Test
		func completeAuthenticationStoresTokenAndEmailUnderUserID() async throws {
			let log = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxCredentialTests.exchangeResponse, onRequest: log.record),
				URLProtocolMock.handler(body: DropboxCredentialTests.account, onRequest: log.record)
			]
			let buffer = TokenBuffer()
			let storage = MemoryTokenStorage(buffer: buffer)

			let credential = try await completeAuthentication(storage: storage)

			#expect(credential.userID == "12345")
			#expect([OAuthAccountKey(provider: .dropbox, account: "12345")] == storage.keys)
			#expect(log.requests.map { $0.url?.absoluteString } == ["https://api.dropboxapi.com/oauth2/token", "https://api.dropboxapi.com/2/users/get_current_account"])
			#expect(log.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer NEW-ACCESS")
			#expect(buffer.token?.accessToken == "NEW-ACCESS")
			#expect(buffer.token?.refreshToken == "NEW-REFRESH")
			#expect(buffer.token?.username == "user@example.com")
			#expect(try credential.cachedUsername() == "user@example.com")
		}

		@Test
		func failedAccountRequestStoresNothing() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxCredentialTests.exchangeResponse),
				URLProtocolMock.handler(statusCode: 400, body: "Error in call to API function")
			]
			let buffer = TokenBuffer()
			buffer.store(DropboxCredentialTests.previousLogin)

			await #expect(throws: DropboxError.apiError(statusCode: 400, summary: "Error in call to API function")) { try await completeAuthentication(storage: MemoryTokenStorage(buffer: buffer)) }
			#expect(DropboxCredentialTests.previousLogin == buffer.token)
		}

		/// The account request finishes even though the task was cancelled meanwhile, so the cancellation is checked before the token is stored.
		@Test
		func cancellationDuringAccountRequestStoresNothing() async throws {
			let accountRequested = TestSignal("account requested")
			let release = DispatchSemaphore(value: 0)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: DropboxCredentialTests.exchangeResponse),
				URLProtocolMock.handler(body: DropboxCredentialTests.account, onRequest: { _ in
					accountRequested.fulfill()
					_ = release.wait(timeout: .now() + testWaitTimeout)
				})
			]
			let buffer = TokenBuffer()
			buffer.store(DropboxCredentialTests.previousLogin)
			let storage = MemoryTokenStorage(buffer: buffer)

			let lockDirectoryURL: URL = lockDirectoryURL
			let authentication = Task {
				try await DropboxCredentialTests.completeAuthentication(storage: storage, lockDirectoryURL: lockDirectoryURL)
			}
			await accountRequested.wait()
			authentication.cancel()
			release.signal()

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: authentication) }
			#expect(DropboxCredentialTests.previousLogin == buffer.token)
		}

		// MARK: - Username

		@Test
		func getUsernameStoresChangedEmail() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxCredentialTests.account)]
			let buffer = TokenBuffer()
			buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "old@example.com"))
			let tokenSource = try makeTokenSource(buffer: buffer)
			let credential = DropboxCredential(userID: "12345", tokenSource: tokenSource)

			let username = try await credential.getUsername(client: .mocked(tokenSource: tokenSource))

			#expect(username == "user@example.com")
			#expect(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "user@example.com") == buffer.token)
		}

		// MARK: - Sign-Out

		@Test
		func deauthenticateDeletesLoginThenRefreshesAndRevokes() async throws {
			for revocationStatus in [200, 500] {
				useNewLockDirectory()
				let buffer = TokenBuffer()
				let log = RequestRecorder()
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(body: #"{"access_token":"FRESH-ACCESS","expires_in":14400}"#, onRequest: { request in
						#expect(buffer.data == nil, "The login must be deleted before the revocation")
						log.record(request)
					}),
					URLProtocolMock.handler(statusCode: revocationStatus, body: "null", onRequest: log.record)
				]
				buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: .distantFuture))
				let credential = try DropboxCredential(userID: "12345", tokenSource: makeTokenSource(buffer: buffer))

				do {
					try await credential.deauthenticate()
					#expect(revocationStatus == 200)
				} catch {
					#expect(.apiError(statusCode: 500, summary: nil) == (error as? DropboxError))
				}

				#expect(buffer.data == nil)
				#expect(log.requests.map { $0.url?.absoluteString } == ["https://api.dropboxapi.com/oauth2/token", "https://api.dropboxapi.com/2/auth/token/revoke"])
				#expect(log.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer FRESH-ACCESS")
			}
		}

		// MARK: - Stored SDK Logins

		@Test
		func storedShortLivedSDKLoginsAreRefreshedAndSavedInPlace() async throws {
			for legacyData in [DropboxFixtures.swiftyDropboxShortLived, DropboxFixtures.objCShortLivedArchive] {
				useNewLockDirectory()
				let log = RequestRecorder()
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","expires_in":14400}"#, onRequest: log.record),
					URLProtocolMock.handler(body: DropboxCredentialTests.account, onRequest: log.record)
				]
				let buffer = TokenBuffer()
				buffer.data = legacyData
				let storage = MemoryTokenStorage(buffer: buffer)

				_ = try await DropboxClient.mocked(tokenSource: makeTokenSource(storage: storage)).currentAccount()

				#expect(log.requests.map { $0.url?.absoluteString } == ["https://api.dropboxapi.com/oauth2/token", "https://api.dropboxapi.com/2/users/get_current_account"])
				#expect(log.requests.first.map(URLProtocolMock.formParameters) == ["grant_type": "refresh_token", "refresh_token": "refresh-token", "client_id": "APP-KEY"])
				#expect(log.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer NEW-ACCESS")
				#expect([OAuthAccountKey(provider: .dropbox, account: "12345")] == storage.keys)
				let storedData = try #require(buffer.data)
				let storedJSON = try #require(JSONSerialization.jsonObject(with: storedData) as? [String: Any])
				#expect((storedJSON["version"] as? Int) == 1)
				#expect((storedJSON["accessToken"] as? String) == "NEW-ACCESS")
				#expect((storedJSON["refreshToken"] as? String) == "refresh-token")
			}
		}

		@Test
		func storedLongLivedSDKLoginsAreSentUnchangedAndNeverRefreshed() async throws {
			let cases: [(name: String, data: Data)] = [
				("SwiftyDropbox", DropboxFixtures.swiftyDropboxLongLived),
				("ObjC archive", DropboxFixtures.objCLongLivedArchive),
				("plain", Data("long-lived-access-token".utf8))
			]
			for (name, data) in cases {
				useNewLockDirectory()
				let log = RequestRecorder()
				URLProtocolMock.requestHandler = [
					URLProtocolMock.handler(body: DropboxCredentialTests.account, onRequest: log.record),
					URLProtocolMock.handler(statusCode: 401, body: DropboxMockResponse.error("invalid_access_token/.."), onRequest: log.record),
					URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","expires_in":14400}"#, onRequest: log.record)
				]
				let buffer = TokenBuffer()
				buffer.data = data
				let client = try DropboxClient.mocked(tokenSource: makeTokenSource(buffer: buffer))

				_ = try await client.currentAccount()
				await #expect(throws: CloudProviderError.unauthorized, "\(name)") { try await client.currentAccount() }

				#expect(Array(repeating: "Bearer long-lived-access-token", count: 2) == log.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, "\(name)")
				#expect(URLProtocolMock.requestHandler.count == 1, "\(name)")
				#expect(data == buffer.data, "\(name)")
			}
		}

		// MARK: - Helpers

		/// The tokens that a store published stay in its process for its lock directory and account, so each login of a loop gets its own directory.
		private func useNewLockDirectory() {
			try? FileManager.default.removeItem(at: lockDirectoryURL)
			lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		}

		private func makeTokenSource(buffer: TokenBuffer) throws -> StoredOAuthTokenSource {
			return try makeTokenSource(storage: MemoryTokenStorage(buffer: buffer))
		}

		private func makeTokenSource(storage: MemoryTokenStorage) throws -> StoredOAuthTokenSource {
			return try DropboxCredential.makeTokenSource(userID: "12345", oauth: .custom(storage: storage, tokenLockDirectory: lockDirectoryURL), endpoint: .mocked(), assertion: ActivityScript().assertion)
		}

		private func completeAuthentication(storage: MemoryTokenStorage) async throws -> DropboxCredential {
			return try await DropboxCredentialTests.completeAuthentication(storage: storage, lockDirectoryURL: lockDirectoryURL)
		}

		private static func completeAuthentication(storage: MemoryTokenStorage, lockDirectoryURL: URL) async throws -> DropboxCredential {
			let endpoint = DropboxOAuthEndpoint.mocked()
			let oauth = try OAuthPersistence.custom(storage: storage, tokenLockDirectory: lockDirectoryURL)
			return try await DropboxCredential.completeAuthentication(authorizationCode: "CODE", codeVerifier: "VERIFIER", endpoint: endpoint, makeClient: { DropboxClient.mocked(tokenSource: $0) }, makeTokenSource: { userID in
				DropboxCredential.makeTokenSource(userID: userID, oauth: oauth, endpoint: endpoint, assertion: ActivityScript().assertion)
			})
		}
	}
}
