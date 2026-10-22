//
//  DropboxCredentialTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DropboxCredentialTests: XCTestCase {
	private static let exchangeResponse = #"{"access_token":"NEW-ACCESS","expires_in":14400,"token_type":"bearer","refresh_token":"NEW-REFRESH","uid":"12345","account_id":"dbid:ACCOUNT"}"#
	private static let account = #"{"account_id":"dbid:ACCOUNT","email":"user@example.com"}"#
	private static let previousLogin = OAuthToken(accessToken: "PREVIOUS", refreshToken: "PREVIOUS-REFRESH", expiresAt: nil, username: "previous@example.com")

	private var lockDirectoryURL: URL!

	override func setUpWithError() throws {
		lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try? FileManager.default.removeItem(at: lockDirectoryURL)
	}

	func testInitThrowsForEmptyUserIDAndMissingSetup() throws {
		let setup = DropboxSetup.constants
		defer {
			DropboxSetup.constants = setup
		}
		DropboxSetup.constants = nil

		XCTAssertThrowsError(try DropboxCredential(userID: "")) { error in
			guard case DropboxCredentialErrors.missingUserID = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
		XCTAssertThrowsError(try DropboxCredential(userID: "12345")) { error in
			guard case DropboxCredentialErrors.missingSetup = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	// MARK: - Login

	func testCompleteAuthenticationStoresTokenAndEmailUnderUserID() async throws {
		let log = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxCredentialTests.exchangeResponse, onRequest: log.record),
			URLProtocolMock.handler(body: DropboxCredentialTests.account, onRequest: log.record)
		]
		let buffer = TokenBuffer()
		let storage = MemoryTokenStorage(buffer: buffer)

		let credential = try await completeAuthentication(storage: storage)

		XCTAssertEqual("12345", credential.userID)
		XCTAssertEqual([OAuthAccountKey(provider: .dropbox, account: "12345")], storage.keys)
		XCTAssertEqual(["https://api.dropboxapi.com/oauth2/token", "https://api.dropboxapi.com/2/users/get_current_account"], log.requests.map { $0.url?.absoluteString })
		XCTAssertEqual("Bearer NEW-ACCESS", log.requests.last?.value(forHTTPHeaderField: "Authorization"))
		XCTAssertEqual("NEW-ACCESS", buffer.token?.accessToken)
		XCTAssertEqual("NEW-REFRESH", buffer.token?.refreshToken)
		XCTAssertEqual("user@example.com", buffer.token?.username)
		XCTAssertEqual("user@example.com", try credential.cachedUsername())
	}

	func testFailedAccountRequestStoresNothing() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: DropboxCredentialTests.exchangeResponse),
			URLProtocolMock.handler(statusCode: 400, body: "Error in call to API function")
		]
		let buffer = TokenBuffer()
		buffer.store(DropboxCredentialTests.previousLogin)

		await XCTAssertThrowsErrorAsync(try await completeAuthentication(storage: MemoryTokenStorage(buffer: buffer))) { error in
			XCTAssertEqual(.apiError(statusCode: 400, summary: "Error in call to API function"), error as? DropboxError)
		}
		XCTAssertEqual(DropboxCredentialTests.previousLogin, buffer.token)
	}

	/// The account request finishes even though the task was cancelled meanwhile, so the cancellation is checked before the token is stored.
	func testCancellationDuringAccountRequestStoresNothing() async throws {
		let accountRequested = XCTestExpectation(description: "account requested")
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
		await fulfillment(of: [accountRequested], timeout: testWaitTimeout)
		authentication.cancel()
		release.signal()

		await XCTAssertThrowsErrorAsync(try await value(of: authentication)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(DropboxCredentialTests.previousLogin, buffer.token)
	}

	// MARK: - Username

	func testGetUsernameStoresChangedEmail() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: DropboxCredentialTests.account)]
		let buffer = TokenBuffer()
		buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "old@example.com"))
		let tokenSource = try makeTokenSource(buffer: buffer)
		let credential = DropboxCredential(userID: "12345", tokenSource: tokenSource)

		let username = try await credential.getUsername(client: .mocked(tokenSource: tokenSource))

		XCTAssertEqual("user@example.com", username)
		XCTAssertEqual(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "user@example.com"), buffer.token)
	}

	// MARK: - Sign-Out

	func testDeauthenticateDeletesLoginThenRefreshesAndRevokes() async throws {
		for revocationStatus in [200, 500] {
			useNewLockDirectory()
			let buffer = TokenBuffer()
			let log = RequestRecorder()
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: #"{"access_token":"FRESH-ACCESS","expires_in":14400}"#, onRequest: { request in
					XCTAssertNil(buffer.data, "The login must be deleted before the revocation")
					log.record(request)
				}),
				URLProtocolMock.handler(statusCode: revocationStatus, body: "null", onRequest: log.record)
			]
			buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: .distantFuture))
			let credential = try DropboxCredential(userID: "12345", tokenSource: makeTokenSource(buffer: buffer))

			do {
				try await credential.deauthenticate()
				XCTAssertEqual(200, revocationStatus)
			} catch {
				XCTAssertEqual(.apiError(statusCode: 500, summary: nil), error as? DropboxError)
			}

			XCTAssertNil(buffer.data)
			XCTAssertEqual(["https://api.dropboxapi.com/oauth2/token", "https://api.dropboxapi.com/2/auth/token/revoke"], log.requests.map { $0.url?.absoluteString })
			XCTAssertEqual("Bearer FRESH-ACCESS", log.requests.last?.value(forHTTPHeaderField: "Authorization"))
		}
	}

	// MARK: - Stored SDK Logins

	func testStoredShortLivedSDKLoginsAreRefreshedAndSavedInPlace() async throws {
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

			XCTAssertEqual(["https://api.dropboxapi.com/oauth2/token", "https://api.dropboxapi.com/2/users/get_current_account"], log.requests.map { $0.url?.absoluteString })
			XCTAssertEqual(["grant_type": "refresh_token", "refresh_token": "refresh-token", "client_id": "APP-KEY"], log.requests.first.map(URLProtocolMock.formParameters))
			XCTAssertEqual("Bearer NEW-ACCESS", log.requests.last?.value(forHTTPHeaderField: "Authorization"))
			XCTAssertEqual([OAuthAccountKey(provider: .dropbox, account: "12345")], storage.keys)
			let storedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(buffer.data)) as? [String: Any])
			XCTAssertEqual(1, storedJSON["version"] as? Int)
			XCTAssertEqual("NEW-ACCESS", storedJSON["accessToken"] as? String)
			XCTAssertEqual("refresh-token", storedJSON["refreshToken"] as? String)
		}
	}

	func testStoredLongLivedSDKLoginsAreSentUnchangedAndNeverRefreshed() async throws {
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
			await XCTAssertThrowsErrorAsync(try await client.currentAccount(), name) { error in
				XCTAssertEqual(.unauthorized, error as? CloudProviderError, name)
			}

			XCTAssertEqual(Array(repeating: "Bearer long-lived-access-token", count: 2), log.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, name)
			XCTAssertEqual(1, URLProtocolMock.requestHandler.count, name)
			XCTAssertEqual(data, buffer.data, name)
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
