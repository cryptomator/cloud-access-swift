//
//  MicrosoftGraphDiscoveryTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 19.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
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
	}
}
