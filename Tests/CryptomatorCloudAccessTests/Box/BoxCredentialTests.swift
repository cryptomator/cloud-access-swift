//
//  BoxCredentialTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class BoxCredentialTests: XCTestCase {
	private var lockDirectoryURL: URL!

	override func setUpWithError() throws {
		lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try? FileManager.default.removeItem(at: lockDirectoryURL)
	}

	func testEmptyUserIDThrows() {
		XCTAssertThrowsError(try BoxCredential(userID: "")) { error in
			guard case BoxCredentialErrors.missingUserID = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testCompleteAuthenticationExchangesCodeAndStoresTokenUnderUserID() async throws {
		let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
		let recordRequest: @Sendable (URLRequest) -> Void = { request in
			var recordedRequest = request
			recordedRequest.httpBody = URLProtocolMock.body(of: request)
			requests.withLock { [recordedRequest] in $0.append(recordedRequest) }
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","expires_in":3600,"refresh_token":"NEW-REFRESH"}"#, onRequest: recordRequest),
			URLProtocolMock.handler(body: BoxMockResponse.user, onRequest: recordRequest)
		]
		let buffer = TokenBuffer()
		let storage = MemoryTokenStorage(buffer: buffer)

		let credential = try await completeAuthentication(storage: storage)

		XCTAssertEqual("USER-ID", credential.userID)
		XCTAssertEqual([OAuthAccountKey(provider: .box, account: "USER-ID")], storage.keys)
		let sentRequests = requests.withLock { $0 }
		XCTAssertEqual(2, sentRequests.count)
		XCTAssertEqual("https://api.box.com/oauth2/token", sentRequests.first?.url?.absoluteString)
		XCTAssertEqual(["grant_type": "authorization_code", "code": "CODE", "client_id": "CLIENT-ID", "client_secret": "SECRET-CLIENT"], sentRequests.first.map(PCloudMockResponse.formParameters))
		XCTAssertEqual("https://api.box.com/2.0/users/me", sentRequests.last?.url?.absoluteString)
		XCTAssertEqual("Bearer NEW-ACCESS", sentRequests.last?.value(forHTTPHeaderField: "Authorization"))
		XCTAssertEqual("NEW-ACCESS", buffer.token?.accessToken)
		XCTAssertEqual("NEW-REFRESH", buffer.token?.refreshToken)
	}

	func testCompleteAuthenticationThrowsIfTokenCannotBeSaved() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","refresh_token":"NEW-REFRESH"}"#),
			URLProtocolMock.handler(body: BoxMockResponse.user)
		]
		let storage = MemoryTokenStorage(buffer: TokenBuffer())
		storage.failsSaves = true

		await XCTAssertThrowsErrorAsync(try await completeAuthentication(storage: storage)) { error in
			XCTAssertEqual(.fileWriteUnknown, (error as? CocoaError)?.code)
		}
	}

	func testStoredSDKLoginIsRefreshedSavedAndRevoked() async throws {
		let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
		let recordRequest: @Sendable (URLRequest) -> Void = { request in
			var recordedRequest = request
			recordedRequest.httpBody = URLProtocolMock.body(of: request)
			requests.withLock { [recordedRequest] in $0.append(recordedRequest) }
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(statusCode: 401, onRequest: recordRequest),
			URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","expires_in":3600,"refresh_token":"NEW-REFRESH"}"#, onRequest: recordRequest),
			URLProtocolMock.handler(body: BoxMockResponse.user, onRequest: recordRequest),
			URLProtocolMock.handler(onRequest: recordRequest)
		]
		let buffer = TokenBuffer()
		buffer.data = Data(#"{"access_token":"LEGACY","refresh_token":"LEGACY-REFRESH","token_type":"bearer"}"#.utf8)
		let tokenSource = try makeTokenSource(buffer: buffer)

		_ = try await BoxClient.mocked(tokenSource: tokenSource).user()

		let sentRequests = requests.withLock { $0 }
		XCTAssertEqual(["Bearer LEGACY", nil, "Bearer NEW-ACCESS"], sentRequests.map { $0.value(forHTTPHeaderField: "Authorization") })
		let tokenRequest = try XCTUnwrap(sentRequests.dropFirst().first)
		XCTAssertEqual("https://api.box.com/oauth2/token", tokenRequest.url?.absoluteString)
		XCTAssertEqual(["grant_type": "refresh_token", "refresh_token": "LEGACY-REFRESH", "client_id": "CLIENT-ID", "client_secret": "SECRET-CLIENT"], PCloudMockResponse.formParameters(of: tokenRequest))
		let storedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(buffer.data)) as? [String: Any])
		XCTAssertEqual(1, storedJSON["version"] as? Int)
		XCTAssertEqual("NEW-ACCESS", storedJSON["accessToken"] as? String)
		XCTAssertEqual("NEW-REFRESH", storedJSON["refreshToken"] as? String)

		try await tokenSource.deauthenticate()

		let revocation = try XCTUnwrap(requests.withLock { $0 }.last)
		XCTAssertEqual("https://api.box.com/oauth2/revoke", revocation.url?.absoluteString)
		XCTAssertEqual("NEW-ACCESS", PCloudMockResponse.formParameters(of: revocation)["token"])
		XCTAssertNil(buffer.data)
	}

	func testGetUsernameWithoutNameThrows() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"type":"user","id":"USER-ID"}"#)]
		let credential = BoxCredential(userID: "USER-ID", tokenSource: OAuthTokenSourceStub())

		await XCTAssertThrowsErrorAsync(try await credential.getUsername(client: .mocked())) { error in
			guard case BoxCredentialErrors.noUsername = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testCompleteAuthenticationStoresUsername() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: #"{"access_token":"NEW-ACCESS","refresh_token":"NEW-REFRESH"}"#),
			URLProtocolMock.handler(body: BoxMockResponse.user)
		]
		let buffer = TokenBuffer()

		let credential = try await completeAuthentication(storage: MemoryTokenStorage(buffer: buffer))

		XCTAssertEqual("User", buffer.token?.username)
		XCTAssertEqual("User", try credential.cachedUsername())
	}

	func testGetUsernameStoresChangedName() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: BoxMockResponse.user)]
		let buffer = TokenBuffer()
		buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "Old Name"))
		let tokenSource = try makeTokenSource(buffer: buffer)
		let credential = BoxCredential(userID: "USER-ID", tokenSource: tokenSource)

		let username = try await credential.getUsername(client: .mocked(tokenSource: tokenSource))

		XCTAssertEqual("User", username)
		XCTAssertEqual(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "User"), buffer.token)
		XCTAssertEqual("User", try credential.cachedUsername())
	}

	func testCachedUsernameOfLegacySDKItemIsNil() throws {
		let buffer = TokenBuffer()
		buffer.data = Data(#"{"access_token":"LEGACY","refresh_token":"LEGACY-REFRESH","token_type":"bearer"}"#.utf8)
		let credential = try BoxCredential(userID: "USER-ID", tokenSource: makeTokenSource(buffer: buffer))

		XCTAssertNil(try credential.cachedUsername())
	}

	private func makeTokenSource(buffer: TokenBuffer) throws -> StoredOAuthTokenSource {
		return try BoxCredential.makeTokenSource(userID: "USER-ID", oauth: .custom(storage: MemoryTokenStorage(buffer: buffer), tokenLockDirectory: lockDirectoryURL), endpoint: .mocked(), assertion: ActivityScript().assertion)
	}

	private func completeAuthentication(storage: MemoryTokenStorage) async throws -> BoxCredential {
		let endpoint = BoxOAuthEndpoint.mocked()
		let oauth = try OAuthPersistence.custom(storage: storage, tokenLockDirectory: lockDirectoryURL)
		return try await BoxCredential.completeAuthentication(authorizationCode: "CODE", endpoint: endpoint, makeClient: { BoxClient.mocked(tokenSource: $0) }, makeTokenSource: { userID in
			BoxCredential.makeTokenSource(userID: userID, oauth: oauth, endpoint: endpoint, assertion: ActivityScript().assertion)
		})
	}
}
