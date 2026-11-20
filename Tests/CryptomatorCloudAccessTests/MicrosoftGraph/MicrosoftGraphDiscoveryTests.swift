//
//  MicrosoftGraphDiscoveryTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import MSAL
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct MicrosoftGraphDiscoveryTests {
		private let discovery: MicrosoftGraphDiscovery

		init() {
			URLProtocolMock.requestHandler = []
			self.discovery = MicrosoftGraphDiscovery(client: .mocked())
		}

		/// The site path is sent as the site URL spells it, so that an escape in the site's name stays as it is.
		@Test
		func siteIsAddressedByHostAndSitePath() async throws {
			let cases: [(siteURL: URL?, expectedPath: String)] = [
				(URL(string: "https://contoso.sharepoint.com/sites/My%20Site"), "/v1.0/sites/contoso.sharepoint.com:/sites/My%20Site"),
				(URL(string: "https://contoso.sharepoint.com/sites/A%2FB"), "/v1.0/sites/contoso.sharepoint.com:/sites/A%2FB"),
				(URL(string: "https://contoso.sharepoint.com/sites/%FF"), "/v1.0/sites/contoso.sharepoint.com:/sites/%FF"),
				(URL(string: "https://contoso.sharepoint.com/sites/Team?web=1"), "/v1.0/sites/contoso.sharepoint.com:/sites/Team"),
				(URL(string: "Team", relativeTo: URL(string: "https://contoso.sharepoint.com/sites/")), "/v1.0/sites/contoso.sharepoint.com:/sites/Team")
			]
			for testCase in cases {
				let siteURL = try #require(testCase.siteURL)
				let requests = RequestRecorder()
				URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"id":"S","displayName":"Site"}"#, onRequest: requests.record)]

				let site = try await discovery.fetchSharePointSite(for: siteURL)

				#expect(site.identifier == "S", "\(siteURL)")
				#expect(site.displayName == "Site", "\(siteURL)")
				#expect(requests.requests.map { $0.url?.path(percentEncoded: true) } == [testCase.expectedPath], "\(siteURL)")
				#expect(requests.requests.map { $0.url?.query } == [nil], "\(siteURL)")
			}
		}

		@Test
		func siteURLOutsideSharePointIsRejectedWithoutRequest() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"id":"S"}"#)]
			let siteURL = try #require(URL(string: "https://contoso.example.com/sites/Team"))

			await #expect(throws: SharePointURLValidationError.invalidURL) { try await discovery.fetchSharePointSite(for: siteURL) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func drivesOfSiteEscapeSiteIdentifier() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"value":[{"id":"D","name":"Documents"}]}"#, onRequest: requests.record)]

			let drives = try await discovery.fetchSharePointDrives(for: "contoso.sharepoint.com,G1,G2")

			#expect(drives.map(\.identifier) == ["D"])
			#expect(drives.map(\.name) == ["Documents"])
			#expect(requests.requests.map { $0.url?.path(percentEncoded: true) } == ["/v1.0/sites/contoso.sharepoint.com%2CG1%2CG2/drives"])
		}

		@Test
		func driveIsAddressedByIdentifier() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"id":"D","name":"Documents"}"#, onRequest: requests.record)]

			let drive = try await discovery.fetchDrive(for: "D")

			#expect(drive.identifier == "D")
			#expect(drive.name == "Documents")
			#expect(requests.requests.map { $0.url?.path(percentEncoded: true) } == ["/v1.0/drives/D"])
		}

		/// A 403 concerns the site or the drive, which signing in again wouldn't fix.
		@Test
		func forbiddenIsPassedThrough() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 403)]

			let error = try await #require(throws: (any Error).self) { try await discovery.fetchDrive(for: "DRIVE") }
			guard case MicrosoftGraphError.unexpectedHTTPStatusCode(code: 403) = error else {
				Issue.record("Unexpected error: \(error)")
				return
			}
		}

		/// MSAL wraps the URL loading system's errors of its token request in its own error.
		@Test
		func connectionFailureThatMSALWrapsThrowsNoInternetConnection() async throws {
			let discovery = discoveryFailingTokenReads(with: MicrosoftGraphDiscoveryTests.msalError(wrapping: URLError(.notConnectedToInternet)))
			let siteURL = try #require(URL(string: "https://contoso.sharepoint.com/sites/Team"))

			await #expect(throws: CloudProviderError.noInternetConnection) { try await discovery.fetchSharePointSite(for: siteURL) }
			await #expect(throws: CloudProviderError.noInternetConnection) { try await discovery.fetchSharePointDrives(for: "SITE") }
			await #expect(throws: CloudProviderError.noInternetConnection) { try await discovery.fetchDrive(for: "DRIVE") }
		}

		@Test
		func cancellationThatMSALWrapsThrowsCancellationError() async throws {
			let discovery = discoveryFailingTokenReads(with: MicrosoftGraphDiscoveryTests.msalError(wrapping: URLError(.cancelled)))
			let siteURL = try #require(URL(string: "https://contoso.sharepoint.com/sites/Team"))

			await #expect(throws: CancellationError.self) { try await discovery.fetchSharePointSite(for: siteURL) }
			await #expect(throws: CancellationError.self) { try await discovery.fetchSharePointDrives(for: "SITE") }
			await #expect(throws: CancellationError.self) { try await discovery.fetchDrive(for: "DRIVE") }
		}

		/// An error in `NSURLErrorDomain` is classified by its own code, so a timeout stays a timeout even if it wraps a cancellation or a failed connection.
		@Test(arguments: [URLError.Code.cancelled, .notConnectedToInternet])
		func outerURLErrorKeepsItsOwnCode(underlyingCode: URLError.Code) async throws {
			let discovery = discoveryFailingTokenReads(with: URLError(.timedOut, userInfo: [NSUnderlyingErrorKey: URLError(underlyingCode)]))

			let error = try await #require(throws: URLError.self) { try await discovery.fetchDrive(for: "DRIVE") }
			#expect(error.code == .timedOut)
		}

		@Test
		func malformedBodyIsPassedThrough() async throws {
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: #"{"name":"Documents"}"#)]

			await #expect(throws: DecodingError.self) { try await discovery.fetchDrive(for: "DRIVE") }
		}

		// MARK: - Helpers

		private func discoveryFailingTokenReads(with error: Error) -> MicrosoftGraphDiscovery {
			let tokenSource = OAuthTokenSourceStub()
			tokenSource.accessTokenError = error
			return MicrosoftGraphDiscovery(client: .mocked(tokenSource: tokenSource))
		}

		/// An error in `MSALErrorDomain` other than `interactionRequired`, which wraps the given error.
		private static func msalError(wrapping underlyingError: URLError) -> NSError {
			return NSError(domain: MSALErrorDomain, code: MSALError.internal.rawValue, userInfo: [NSUnderlyingErrorKey: underlyingError])
		}
	}
}
