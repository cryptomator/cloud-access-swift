//
//  MicrosoftGraphTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 16.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

/// The host of a download task's original request and whether it is Graph's `/content`, without the path, which names the account on a content host and would otherwise reach the test log.
private struct RecordedDownload: Sendable {
	let host: String?
	let isThroughGraph: Bool
}

extension IntegrationTests.ProviderSpecific {
	@Suite(.enabled(if: IntegrationBackend.isSelected(.microsoftGraph)))
	struct MicrosoftGraphTests {
		private static let backend = IntegrationBackend(.microsoftGraph, .plain)

		/// The conformance tests can't tell the download URL from `/content`, because a refused download URL falls back to `/content`.
		@Test
		func fileIsDownloadedFromDownloadURL() async throws {
			try await withIntegrationFixture(MicrosoftGraphTests.backend) { context in
				let downloads = OSAllocatedUnfairLock(initialState: [RecordedDownload]())
				let hooks = SplitURLSession.Hooks(willProcessCompletion: { task in
					if task is URLSessionDownloadTask, let url = task.originalRequest?.url {
						downloads.withLock { $0.append(RecordedDownload(host: url.host(), isThroughGraph: url.path.hasSuffix("/content"))) }
					}
				})
				let client = MicrosoftGraphHTTPClient(tokenSource: SharedCredentials.microsoftGraph.tokenSource, configuration: MicrosoftGraphHTTPClient.foregroundConfiguration(), metadataConfiguration: nil, hooks: hooks)
				let provider = try MicrosoftGraphCloudProvider(client: client)
				let cloudPath = try await context.makeSandbox().appendingPathComponent("file.txt")

				try await expectUploadRoundTrips(ofLength: 1024, to: cloudPath, through: provider, in: context)

				let recordedDownloads = downloads.withLock { $0 }
				#expect(!recordedDownloads.contains { $0.isThroughGraph })
				#expect(recordedDownloads.contains { $0.host != MicrosoftGraphAPI.host })
			}
		}
	}
}
