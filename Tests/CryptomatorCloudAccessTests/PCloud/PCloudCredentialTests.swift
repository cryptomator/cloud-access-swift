//
//  PCloudCredentialTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class PCloudCredentialTests: XCTestCase {
	private static let userInfo = #"{"result":0,"email":"user@example.com","userid":7}"#
	/// The JSON in which the pCloud SDK stored its `OAuth.User`.
	private static let legacyUser = #"{"id":7,"token":"LEGACY","serverRegionId":2,"httpAPIHostName":"eapi.pcloud.com"}"#

	private var lockDirectoryURL: URL!

	override func setUpWithError() throws {
		lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try? FileManager.default.removeItem(at: lockDirectoryURL)
	}

	func testEmptyUserIDThrows() throws {
		let setup = try PCloudSetup(appKey: "APP-KEY", oauth: .custom(storage: MemoryTokenStorage(buffer: TokenBuffer()), tokenLockDirectory: lockDirectoryURL))

		XCTAssertThrowsError(try PCloudCredential(userID: "", setup: setup)) { error in
			guard case PCloudCredentialError.missingUserID = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	// MARK: - Login

	func testCompleteAuthenticationStoresTokenWithHostAndEmailUnderUserID() async throws {
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo, onRequest: requests.record)]
		let buffer = TokenBuffer()
		let storage = MemoryTokenStorage(buffer: buffer)

		let credential = try await completeAuthentication(apiHostName: "EAPI.pcloud.com", storage: storage)

		XCTAssertEqual("7", credential.userID)
		XCTAssertEqual([OAuthAccountKey(provider: .pCloud, account: "7")], storage.keys)
		XCTAssertEqual("https://eapi.pcloud.com/userinfo", requests.requests.first?.url?.absoluteString)
		XCTAssertEqual("NEW-ACCESS", requests.requests.first.map(URLProtocolMock.formParameters)?["access_token"])
		XCTAssertEqual(OAuthToken(accessToken: "NEW-ACCESS", refreshToken: nil, expiresAt: nil, username: "user@example.com", apiHost: "eapi.pcloud.com"), buffer.token)
		XCTAssertEqual("user@example.com", try credential.cachedUsername())
	}

	func testCompleteAuthenticationRejectsHostOutsidePCloudWithoutRequest() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo)]
		let buffer = TokenBuffer()

		for apiHostName in ["evil.example", "evilpcloud.com", "evil.com/.pcloud.com"] {
			await XCTAssertThrowsErrorAsync(try await completeAuthentication(apiHostName: apiHostName, storage: MemoryTokenStorage(buffer: buffer)), apiHostName) { error in
				XCTAssertEqual(.badURL, (error as? URLError)?.code, apiHostName)
			}
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
		XCTAssertNil(buffer.data)
	}

	/// The account request finishes even though the task was cancelled meanwhile, so the cancellation is checked before the token is stored.
	func testCancellationDuringAccountRequestStoresNothing() async throws {
		let accountRequested = XCTestExpectation(description: "account requested")
		let release = DispatchSemaphore(value: 0)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo, onRequest: { _ in
			accountRequested.fulfill()
			_ = release.wait(timeout: .now() + testWaitTimeout)
		})]
		let buffer = TokenBuffer()
		let storage = MemoryTokenStorage(buffer: buffer)

		let lockDirectoryURL: URL = lockDirectoryURL
		let authentication = Task {
			try await PCloudCredentialTests.completeAuthentication(apiHostName: "eapi.pcloud.com", storage: storage, lockDirectoryURL: lockDirectoryURL)
		}
		await fulfillment(of: [accountRequested], timeout: testWaitTimeout)
		authentication.cancel()
		release.signal()

		await XCTAssertThrowsErrorAsync(try await value(of: authentication)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertNil(buffer.token)
	}

	// MARK: - Stored Logins

	func testStoredSDKLoginIsSentToItsHostAndKeepsItWithUsername() async throws {
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo, onRequest: requests.record)]
		let buffer = TokenBuffer()
		buffer.data = Data(PCloudCredentialTests.legacyUser.utf8)
		let tokenSource = try makeTokenSource(buffer: buffer)
		let credential = PCloudCredential(userID: "7", tokenSource: tokenSource)

		XCTAssertNil(try credential.cachedUsername())
		let username = try await credential.getUsername(client: .mocked(tokenSource: tokenSource))

		XCTAssertEqual("user@example.com", username)
		XCTAssertEqual("https://eapi.pcloud.com/userinfo", requests.requests.first?.url?.absoluteString)
		XCTAssertEqual("LEGACY", requests.requests.first.map(URLProtocolMock.formParameters)?["access_token"])
		XCTAssertEqual(OAuthToken(accessToken: "LEGACY", refreshToken: nil, expiresAt: nil, username: "user@example.com", apiHost: "eapi.pcloud.com"), buffer.token)
		XCTAssertEqual(PCloudLogin(accessToken: "LEGACY", apiHost: "eapi.pcloud.com"), try tokenSource.login())
	}

	func testStoredTokenWithoutHostIsUnauthorized() throws {
		let buffer = TokenBuffer()
		buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: nil, expiresAt: nil))

		XCTAssertThrowsError(try makeTokenSource(buffer: buffer).login()) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
	}

	func testDeauthenticateDeletesLoginWithoutRequest() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo)]
		let buffer = TokenBuffer()
		buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: nil, expiresAt: nil, apiHost: "eapi.pcloud.com"))
		let credential = try PCloudCredential(userID: "7", tokenSource: makeTokenSource(buffer: buffer))

		try await credential.deauthenticate()

		XCTAssertNil(buffer.data)
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	/// pCloud tokens never expire, so a process must not keep using the token of a login that another process deleted.
	func testLoginDeletedByAnotherProcessIsUnauthorized() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudCredentialTests.userInfo), URLProtocolMock.handler(body: PCloudCredentialTests.userInfo)]
		let buffer = TokenBuffer()
		buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: nil, expiresAt: nil, apiHost: "eapi.pcloud.com"))
		let fileProviderTokenSource = try makeTokenSource(buffer: buffer, coordinator: OAuthTokenCoordinator())
		let appTokenSource = try makeTokenSource(buffer: buffer, coordinator: OAuthTokenCoordinator())
		let client = PCloudClient.mocked(tokenSource: fileProviderTokenSource)
		_ = try await fileProviderTokenSource.accessToken()
		_ = try await client.userInfoEmail()

		try await appTokenSource.deauthenticate()

		await XCTAssertThrowsErrorAsync(try await client.userInfoEmail()) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testGetUsernameThrowsAPIError() async throws {
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: PCloudMockResponse.result(2009))]
		let credential = PCloudCredential(userID: "7", tokenSource: PCloudCredential.stubTokenSource)

		await XCTAssertThrowsErrorAsync(try await credential.getUsername(client: .mocked())) { error in
			XCTAssertEqual(.apiError(code: 2009, message: "Error 2009."), error as? PCloudError)
		}
	}

	// MARK: - API Hosts

	func testAcceptsAPIHostNames() {
		XCTAssertEqual("api.pcloud.com", PCloudCredential.apiHost("api.pcloud.com"))
		XCTAssertEqual("eapi.pcloud.com", PCloudCredential.apiHost("EAPI.PCLOUD.COM"))
	}

	func testRejectsAPIHostNamesThatAreNoBareHostNamesOfPCloud() {
		for apiHostName in ["evil.com/.pcloud.com", "evil.com?.pcloud.com", "evil.com#.pcloud.com", "user@evil.com", "api.pcloud.com:8443", "api..pcloud.com", "", "[::1]", "api.pcloud.com.", "api pcloud.com", "äpi.pcloud.com", "evil.example", "evilpcloud.com", "1.2.3.4"] {
			XCTAssertNil(PCloudCredential.apiHost(apiHostName), apiHostName)
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
