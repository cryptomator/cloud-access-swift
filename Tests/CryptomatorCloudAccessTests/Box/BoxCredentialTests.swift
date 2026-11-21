//
//  BoxCredentialTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class BoxCredentialTests {
		private static let previousLogin = OAuthToken(accessToken: "PREVIOUS", refreshToken: "PREVIOUS-REFRESH", expiresAt: nil, username: "Previous")

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
			let setup = try BoxSetup(clientID: "CLIENT", clientSecret: "SECRET", oauth: .custom(storage: MemoryTokenStorage(buffer: TokenBuffer()), tokenLockDirectory: lockDirectoryURL))

			#expect(throws: BoxCredentialError.missingUserID) { try BoxCredential(userID: "", setup: setup) }
		}

		@Test
		func completeAuthenticationExchangesCodeAndStoresTokenUnderUserID() async throws {
			let recorder = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","expires_in":3600,"refresh_token":"NEW-REFRESH"}"#, onRequest: recorder.record),
				URLProtocolMock.handler(body: BoxMockResponse.user, onRequest: recorder.record)
			]
			let buffer = TokenBuffer()
			let storage = MemoryTokenStorage(buffer: buffer)

			let credential = try await completeAuthentication(storage: storage)

			#expect(credential.userID == "USER-ID")
			#expect([OAuthAccountKey(provider: .box, account: "USER-ID")] == storage.keys)
			let sentRequests = recorder.requests
			#expect(sentRequests.count == 2)
			#expect(sentRequests.first?.url?.absoluteString == "https://api.box.com/oauth2/token")
			#expect(sentRequests.first.map(URLProtocolMock.formParameters) == ["grant_type": "authorization_code", "code": "CODE", "client_id": "CLIENT-ID", "client_secret": "SECRET-CLIENT"])
			#expect(sentRequests.last?.url?.absoluteString == "https://api.box.com/2.0/users/me")
			#expect(sentRequests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer NEW-ACCESS")
			#expect(buffer.token?.accessToken == "NEW-ACCESS")
			#expect(buffer.token?.refreshToken == "NEW-REFRESH")
		}

		@Test
		func completeAuthenticationThrowsIfTokenCannotBeSaved() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","refresh_token":"NEW-REFRESH"}"#),
				URLProtocolMock.handler(body: BoxMockResponse.user)
			]
			let storage = MemoryTokenStorage(buffer: TokenBuffer())
			storage.failsSaves = true

			let error = try await #require(throws: (any Error).self) { try await completeAuthentication(storage: storage) }
			#expect((error as? CocoaError)?.code == .fileWriteUnknown)
		}

		/// The user request finishes even though the task was cancelled meanwhile, so the cancellation is checked before the token is stored.
		@Test
		func cancellationDuringUserRequestStoresNothing() async throws {
			let userRequested = TestSignal("user requested")
			let release = DispatchSemaphore(value: 0)
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","expires_in":3600,"refresh_token":"NEW-REFRESH"}"#),
				URLProtocolMock.handler(body: BoxMockResponse.user, onRequest: { _ in
					userRequested.fulfill()
					_ = release.wait(timeout: testWaitDeadline())
				})
			]
			let buffer = TokenBuffer()
			let storage = MemoryTokenStorage(buffer: buffer)

			let lockDirectoryURL = lockDirectoryURL
			let authentication = Task {
				try await BoxCredentialTests.completeAuthentication(storage: storage, lockDirectoryURL: lockDirectoryURL)
			}
			await userRequested.wait()
			authentication.cancel()
			release.signal()

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: authentication) }
			#expect(buffer.token == nil)
		}

		@Test
		func storedSDKLoginIsRefreshedSavedAndRevoked() async throws {
			let recorder = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(statusCode: 401, onRequest: recorder.record),
				URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","expires_in":3600,"refresh_token":"NEW-REFRESH"}"#, onRequest: recorder.record),
				URLProtocolMock.handler(body: BoxMockResponse.user, onRequest: recorder.record),
				URLProtocolMock.handler(onRequest: recorder.record)
			]
			let buffer = TokenBuffer()
			buffer.data = Data(#"{"access_token":"LEGACY","refresh_token":"LEGACY-REFRESH","token_type":"bearer"}"#.utf8)
			let tokenSource = try makeTokenSource(buffer: buffer)

			_ = try await BoxClient.mocked(tokenSource: tokenSource).user()

			let sentRequests = recorder.requests
			#expect(sentRequests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer LEGACY", nil, "Bearer NEW-ACCESS"])
			let tokenRequest = try #require(sentRequests.dropFirst().first)
			#expect(tokenRequest.url?.absoluteString == "https://api.box.com/oauth2/token")
			#expect(URLProtocolMock.formParameters(of: tokenRequest) == ["grant_type": "refresh_token", "refresh_token": "LEGACY-REFRESH", "client_id": "CLIENT-ID", "client_secret": "SECRET-CLIENT"])
			let storedData = try #require(buffer.data)
			let storedJSON = try #require(JSONSerialization.jsonObject(with: storedData) as? [String: Any])
			#expect((storedJSON["version"] as? Int) == 1)
			#expect((storedJSON["accessToken"] as? String) == "NEW-ACCESS")
			#expect((storedJSON["refreshToken"] as? String) == "NEW-REFRESH")

			try await tokenSource.deauthenticate()

			let revocation = try #require(recorder.requests.last)
			#expect(revocation.url?.absoluteString == "https://api.box.com/oauth2/revoke")
			#expect(URLProtocolMock.formParameters(of: revocation)["token"] == "NEW-ACCESS")
			#expect(buffer.data == nil)
		}

		@Test
		func getUsernameWithoutNameThrows() async {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"type":"user","id":"USER-ID"}"#)]
			let credential = BoxCredential(userID: "USER-ID", tokenSource: OAuthTokenSourceStub())

			await #expect(throws: BoxCredentialError.noUsername) { try await credential.getUsername(client: .mocked()) }
		}

		@Test
		func completeAuthenticationStoresUsername() async throws {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","refresh_token":"NEW-REFRESH"}"#),
				URLProtocolMock.handler(body: BoxMockResponse.user)
			]
			let buffer = TokenBuffer()

			let credential = try await completeAuthentication(storage: MemoryTokenStorage(buffer: buffer))

			#expect(buffer.token?.username == "User")
			#expect(try credential.cachedUsername() == "User")
		}

		@Test
		func getUsernameStoresChangedName() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: BoxMockResponse.user)]
			let buffer = TokenBuffer()
			buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "Old Name"))
			let tokenSource = try makeTokenSource(buffer: buffer)
			let credential = BoxCredential(userID: "USER-ID", tokenSource: tokenSource)

			let username = try await credential.getUsername(client: .mocked(tokenSource: tokenSource))

			#expect(username == "User")
			#expect(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "User") == buffer.token)
			#expect(try credential.cachedUsername() == "User")
		}

		@Test
		func cachedUsernameOfLegacySDKItemIsNil() throws {
			let buffer = TokenBuffer()
			buffer.data = Data(#"{"access_token":"LEGACY","refresh_token":"LEGACY-REFRESH","token_type":"bearer"}"#.utf8)
			let credential = try BoxCredential(userID: "USER-ID", tokenSource: makeTokenSource(buffer: buffer))

			#expect(try credential.cachedUsername() == nil)
		}

		@Test
		func hasStoredLoginOnlyWhileALoginIsStored() throws {
			let buffer = TokenBuffer()
			let credential = try BoxCredential(userID: "USER-ID", tokenSource: makeTokenSource(buffer: buffer))

			#expect(try !credential.hasStoredLogin())

			// A login that the Box SDK stored has no username, so `cachedUsername()` can't tell whether one is stored.
			buffer.data = Data(#"{"access_token":"LEGACY","refresh_token":"LEGACY-REFRESH","token_type":"bearer"}"#.utf8)

			#expect(try credential.hasStoredLogin())
		}

		/// A failed user request throws what the provider's operations throw for its response.
		@Test(arguments: BoxAccountFailure.mapped)
		func getUsernameThrowsMappedError(_ failure: BoxAccountFailure) async {
			URLProtocolMock.requestHandler = [failure.response]
			let credential = BoxCredential(userID: "USER-ID", tokenSource: OAuthTokenSourceStub())

			await #expect(throws: failure.expectedError) { try await credential.getUsername(client: .mocked()) }
		}

		@Test
		func getUsernameThrowsUnauthorizedIfRefreshedTokenIsRejected() async {
			let tokenSource = OAuthTokenSourceStub()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 401), URLProtocolMock.handler(statusCode: 401)]
			let credential = BoxCredential(userID: "USER-ID", tokenSource: tokenSource)

			await #expect(throws: CloudProviderError.unauthorized) { try await credential.getUsername(client: .mocked(tokenSource: tokenSource)) }
			#expect(tokenSource.rejectedTokens == ["TOKEN"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A 403 about an item or a policy isn't fixed by signing in again.
		@Test
		func getUsernameKeepsOtherForbiddenRaw() async {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 403, body: BoxMockResponse.error(status: 403, code: "access_denied_insufficient_permissions"))]
			let credential = BoxCredential(userID: "USER-ID", tokenSource: OAuthTokenSourceStub())

			await #expect(throws: BoxError.apiError(statusCode: 403, code: "access_denied_insufficient_permissions", message: nil)) { try await credential.getUsername(client: .mocked()) }
		}

		@Test(arguments: BoxAccountFailure.mapped)
		func failedUserRequestAtLoginThrowsMappedErrorAndStoresNothing(_ failure: BoxAccountFailure) async {
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","refresh_token":"NEW-REFRESH"}"#),
				failure.response
			]
			let buffer = TokenBuffer()
			buffer.store(BoxCredentialTests.previousLogin)

			await #expect(throws: failure.expectedError) { try await completeAuthentication(storage: MemoryTokenStorage(buffer: buffer)) }
			#expect(BoxCredentialTests.previousLogin == buffer.token)
		}

		/// The sender returns a 401 on its last attempt before it could refresh, so the login maps it itself.
		@Test
		func unauthorizedLastUserRequestAtLoginThrowsUnauthorizedAndStoresNothing() async {
			let userRequests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","refresh_token":"NEW-REFRESH"}"#)]
				+ Array(repeating: URLProtocolMock.handler(statusCode: 503, onRequest: userRequests.record), count: 4)
				+ [URLProtocolMock.handler(statusCode: 401, onRequest: userRequests.record)]
			let buffer = TokenBuffer()
			buffer.store(BoxCredentialTests.previousLogin)

			await #expect(throws: CloudProviderError.unauthorized) { try await completeAuthentication(storage: MemoryTokenStorage(buffer: buffer)) }
			#expect(userRequests.requests.count == 5)
			#expect(BoxCredentialTests.previousLogin == buffer.token)
		}

		private func makeTokenSource(buffer: TokenBuffer) throws -> StoredOAuthTokenSource {
			return try BoxCredential.makeTokenSource(userID: "USER-ID", oauth: .custom(storage: MemoryTokenStorage(buffer: buffer), tokenLockDirectory: lockDirectoryURL), endpoint: .mocked(), assertion: ActivityScript().assertion)
		}

		private func completeAuthentication(storage: MemoryTokenStorage) async throws -> BoxCredential {
			return try await BoxCredentialTests.completeAuthentication(storage: storage, lockDirectoryURL: lockDirectoryURL)
		}

		private static func completeAuthentication(storage: MemoryTokenStorage, lockDirectoryURL: URL) async throws -> BoxCredential {
			let endpoint = BoxOAuthEndpoint.mocked()
			let oauth = try OAuthPersistence.custom(storage: storage, tokenLockDirectory: lockDirectoryURL)
			return try await BoxCredential.completeAuthentication(authorizationCode: "CODE", endpoint: endpoint, makeClient: { BoxClient.mocked(tokenSource: $0) }, makeTokenSource: { userID in
				BoxCredential.makeTokenSource(userID: userID, oauth: oauth, endpoint: endpoint, assertion: ActivityScript().assertion)
			})
		}
	}
}

/// A response to the user request that the provider's operations map.
struct BoxAccountFailure: Sendable, CustomTestStringConvertible {
	static let mapped = [
		BoxAccountFailure(statusCode: 403, code: "insufficient_scope", expectedError: .unauthorized),
		BoxAccountFailure(statusCode: 403, code: "storage_limit_exceeded", expectedError: .quotaInsufficient),
		BoxAccountFailure(statusCode: 404, code: "not_found", expectedError: .itemNotFound)
	]

	let statusCode: Int
	let code: String
	let expectedError: CloudProviderError

	var response: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
		return URLProtocolMock.handler(statusCode: statusCode, body: BoxMockResponse.error(status: statusCode, code: code))
	}

	var testDescription: String {
		return "\(statusCode) \(code)"
	}
}
