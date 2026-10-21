//
//  GoogleDriveCredentialTests.swift
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

class GoogleDriveCredentialTests: XCTestCase {
	private var lockDirectoryURL: URL!
	private var buffer: TokenBuffer!
	private var storage: MemoryTokenStorage!
	private var oauth: OAuthPersistence!

	override func setUpWithError() throws {
		lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		buffer = TokenBuffer()
		storage = MemoryTokenStorage(buffer: buffer)
		oauth = try .custom(storage: storage, tokenLockDirectory: lockDirectoryURL)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try? FileManager.default.removeItem(at: lockDirectoryURL)
	}

	func testEmptyUserIDThrows() {
		XCTAssertThrowsError(try GoogleDriveCredential(userID: "")) { error in
			guard case GoogleDriveCredentialError.missingUserID = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
	}

	func testCompleteAuthenticationStoresTokenAndEmailUnderSubject() async throws {
		let idToken = GoogleDriveCredentialTests.idToken(claims: #"{"iss":"https://accounts.google.com","aud":"CLIENT-ID","iat":1792000000,"exp":1792003600,"sub":"112233","email":"user@example.com"}"#)

		let credential = try await GoogleDriveCredential.completeAuthentication(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: Date(timeIntervalSince1970: 1_792_000_000), idToken: idToken, makeTokenSource: makeTokenSource(userID:))

		XCTAssertEqual("112233", credential.userID)
		XCTAssertEqual(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: Date(timeIntervalSince1970: 1_792_000_000), username: "user@example.com"), buffer.token)
		XCTAssertEqual("user@example.com", try credential.cachedUsername())
		XCTAssertEqual([OAuthAccountKey(provider: .googleDrive, account: "112233")], storage.keys)
	}

	func testCompleteAuthenticationWithoutSubjectThrows() async throws {
		let idToken = GoogleDriveCredentialTests.idToken(claims: #"{"iss":"https://accounts.google.com","aud":"CLIENT-ID","iat":1792000000,"exp":1792003600,"email":"user@example.com"}"#)

		await XCTAssertThrowsErrorAsync(try await GoogleDriveCredential.completeAuthentication(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, idToken: idToken, makeTokenSource: makeTokenSource(userID:))) { error in
			guard case GoogleDriveCredentialError.missingUserID = error else {
				XCTFail("Unexpected error: \(error)")
				return
			}
		}
		XCTAssertNil(buffer.data)
	}

	func testStoredGTMAppAuthLoginHasCachedUsername() throws {
		buffer.data = GoogleDriveFixtures.gtmAppAuth6
		let credential = GoogleDriveCredential(userID: GoogleDriveFixtures.userID, tokenSource: makeTokenSource(userID: GoogleDriveFixtures.userID))

		XCTAssertEqual(GoogleDriveFixtures.email, try credential.cachedUsername())
	}

	func testGetUsernameStoresChangedEmail() async throws {
		buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "old@example.com"))
		let tokenSource = makeTokenSource(userID: "112233")
		let credential = GoogleDriveCredential(userID: "112233", tokenSource: tokenSource)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"user":{"emailAddress":"new@example.com"}}"#)]

		let username = try await credential.getUsername(client: .mocked(tokenSource: tokenSource))

		XCTAssertEqual("new@example.com", username)
		XCTAssertEqual(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "new@example.com"), buffer.token)
	}

	func testGetUsernameReturnsEmailThatCannotBeStored() async throws {
		let tokenSource = OAuthTokenSourceStub(username: "old@example.com")
		tokenSource.failsUsernameUpdates = true
		let credential = GoogleDriveCredential(userID: "112233", tokenSource: tokenSource)
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"user":{"emailAddress":"new@example.com"}}"#)]

		let username = try await credential.getUsername(client: .mocked(tokenSource: tokenSource))

		XCTAssertEqual("new@example.com", username)
		XCTAssertEqual("old@example.com", try credential.cachedUsername())
	}

	func testDeauthenticateDeletesLoginWithoutRequest() async throws {
		buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil))
		let credential = GoogleDriveCredential(userID: "112233", tokenSource: makeTokenSource(userID: "112233"))
		URLProtocolMock.requestHandler = [URLProtocolMock.handler()]

		try await credential.deauthenticate()

		XCTAssertNil(buffer.data)
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	// MARK: - Helpers

	private func makeTokenSource(userID: String) -> StoredOAuthTokenSource {
		return GoogleDriveCredential.makeTokenSource(userID: userID, oauth: oauth, endpoint: .mocked(), assertion: ActivityScript().assertion)
	}

	/// An unsigned ID token with the claims, which is enough for a token that the token endpoint returned.
	private static func idToken(claims: String) -> String {
		let encode: (String) -> String = { string in
			Data(string.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
		}
		return "\(encode(#"{"alg":"RS256","typ":"JWT"}"#)).\(encode(claims)).c2ln"
	}
}
