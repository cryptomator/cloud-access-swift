//
//  GoogleDriveCredentialTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class GoogleDriveCredentialTests {
		private let lockDirectoryURL: URL
		private let buffer: TokenBuffer
		private let storage: MemoryTokenStorage
		private let oauth: OAuthPersistence

		init() throws {
			URLProtocolMock.requestHandler = []
			self.lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			self.buffer = TokenBuffer()
			self.storage = MemoryTokenStorage(buffer: buffer)
			self.oauth = try .custom(storage: storage, tokenLockDirectory: lockDirectoryURL)
		}

		deinit {
			guard FileManager.default.fileExists(atPath: lockDirectoryURL.path) else {
				return
			}
			removeItemRecordingFailure(at: lockDirectoryURL)
		}

		@Test
		func emptyUserIDThrows() throws {
			let setup = try GoogleDriveSetup(clientID: "CLIENT", redirectURL: #require(URL(string: "com.example:/oauth2redirect")), oauth: oauth)

			#expect(throws: GoogleDriveCredentialError.missingUserID) { try GoogleDriveCredential(userID: "", setup: setup) }
		}

		@Test
		func completeAuthenticationStoresTokenAndEmailUnderSubject() async throws {
			let idToken = GoogleDriveCredentialTests.idToken(claims: #"{"iss":"https://accounts.google.com","aud":"CLIENT-ID","iat":1792000000,"exp":1792003600,"sub":"112233","email":"user@example.com"}"#)

			let credential = try await GoogleDriveCredential.completeAuthentication(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: Date(timeIntervalSince1970: 1_792_000_000), idToken: idToken, makeTokenSource: makeTokenSource(userID:))

			#expect(credential.userID == "112233")
			#expect(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: Date(timeIntervalSince1970: 1_792_000_000), username: "user@example.com") == buffer.token)
			#expect(try credential.cachedUsername() == "user@example.com")
			#expect([OAuthAccountKey(provider: .googleDrive, account: "112233")] == storage.keys)
		}

		@Test
		func completeAuthenticationWithoutSubjectThrows() async {
			let idToken = GoogleDriveCredentialTests.idToken(claims: #"{"iss":"https://accounts.google.com","aud":"CLIENT-ID","iat":1792000000,"exp":1792003600,"email":"user@example.com"}"#)

			await #expect(throws: GoogleDriveCredentialError.missingUserID) { try await GoogleDriveCredential.completeAuthentication(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, idToken: idToken, makeTokenSource: makeTokenSource(userID:)) }
			#expect(buffer.data == nil)
		}

		@Test
		func cancelledTaskStoresNothing() async throws {
			let idToken = GoogleDriveCredentialTests.idToken(claims: #"{"iss":"https://accounts.google.com","aud":"CLIENT-ID","iat":1792000000,"exp":1792003600,"sub":"112233","email":"user@example.com"}"#)
			let oauth: OAuthPersistence = oauth
			let authentication = cancelledTask {
				try await GoogleDriveCredential.completeAuthentication(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, idToken: idToken, makeTokenSource: { userID in
					GoogleDriveCredential.makeTokenSource(userID: userID, oauth: oauth, endpoint: .mocked(), assertion: ActivityScript().assertion)
				})
			}

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: authentication) }
			#expect(buffer.data == nil)
		}

		@Test
		func storedGTMAppAuthLoginHasCachedUsername() throws {
			buffer.data = GoogleDriveFixtures.gtmAppAuth6
			let credential = GoogleDriveCredential(userID: GoogleDriveFixtures.userID, tokenSource: makeTokenSource(userID: GoogleDriveFixtures.userID))

			#expect(try GoogleDriveFixtures.email == credential.cachedUsername())
		}

		@Test
		func getUsernameStoresChangedEmail() async throws {
			buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "old@example.com"))
			let tokenSource = makeTokenSource(userID: "112233")
			let credential = GoogleDriveCredential(userID: "112233", tokenSource: tokenSource)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"user":{"emailAddress":"new@example.com"}}"#)]

			let username = try await credential.getUsername(client: .mocked(tokenSource: tokenSource))

			#expect(username == "new@example.com")
			#expect(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil, username: "new@example.com") == buffer.token)
		}

		@Test
		func getUsernameReturnsEmailThatCannotBeStored() async throws {
			let tokenSource = OAuthTokenSourceStub(username: "old@example.com")
			tokenSource.failsUsernameUpdates = true
			let credential = GoogleDriveCredential(userID: "112233", tokenSource: tokenSource)
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"user":{"emailAddress":"new@example.com"}}"#)]

			let username = try await credential.getUsername(client: .mocked(tokenSource: tokenSource))

			#expect(username == "new@example.com")
			#expect(try credential.cachedUsername() == "old@example.com")
		}

		@Test
		func deauthenticateDeletesLoginWithoutRequest() async throws {
			buffer.store(OAuthToken(accessToken: "ACCESS", refreshToken: "REFRESH", expiresAt: nil))
			let credential = GoogleDriveCredential(userID: "112233", tokenSource: makeTokenSource(userID: "112233"))
			URLProtocolMock.requestHandler = [URLProtocolMock.handler()]

			try await credential.deauthenticate()

			#expect(buffer.data == nil)
			#expect(URLProtocolMock.requestHandler.count == 1)
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
}
