//
//  SplitSessionClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct SplitSessionClientTests {
		@Test
		func foregroundClientHasNoMetadataConfiguration() {
			let client = RecordingClient.foreground(tokenSource: "TOKEN")

			#expect(client.tokenSource == "TOKEN")
			#expect(client.configuration.identifier == nil)
			expectHardened(client.configuration)
			#expect(client.metadataConfiguration == nil)
			#expect(client.registry === BackgroundURLSessionRegistry.shared)
		}

		@Test
		func backgroundClientHasForegroundMetadataConfiguration() throws {
			let client = RecordingClient.background(tokenSource: "TOKEN", sessionIdentifier: "SplitSessionClientTests", sharedContainerIdentifier: "group.test")

			#expect(client.tokenSource == "TOKEN")
			#expect(client.configuration.identifier == "SplitSessionClientTests")
			#expect(client.configuration.sharedContainerIdentifier == "group.test")
			expectHardened(client.configuration)
			let metadataConfiguration = try #require(client.metadataConfiguration)
			#expect(metadataConfiguration.identifier == nil)
			expectHardened(metadataConfiguration)
			#expect(client.registry === BackgroundURLSessionRegistry.shared)
		}
	}
}

/// Records what the factories pass to its initializer.
private struct RecordingClient: SplitSessionClient {
	let tokenSource: String
	let configuration: URLSessionConfiguration
	let metadataConfiguration: URLSessionConfiguration?
	let registry: BackgroundURLSessionRegistry

	init(tokenSource: String, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks, registry: BackgroundURLSessionRegistry, sleep: @escaping @Sendable (Duration) async throws -> Void) {
		self.tokenSource = tokenSource
		self.configuration = configuration
		self.metadataConfiguration = metadataConfiguration
		self.registry = registry
	}
}
