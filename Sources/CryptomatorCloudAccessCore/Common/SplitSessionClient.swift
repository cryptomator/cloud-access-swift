//
//  SplitSessionClient.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 21.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// A client whose designated init takes the configurations of a `SplitURLSession`, so that its factories create it over hardened foreground or background configurations.
protocol SplitSessionClient {
	associatedtype TokenSource

	init(tokenSource: TokenSource, configuration: URLSessionConfiguration, metadataConfiguration: URLSessionConfiguration?, hooks: SplitURLSession.Hooks, registry: BackgroundURLSessionRegistry, sleep: @escaping @Sendable (Duration) async throws -> Void)
}

extension SplitSessionClient {
	static func foreground(tokenSource: TokenSource) -> Self {
		return Self(tokenSource: tokenSource, configuration: foregroundConfiguration(), metadataConfiguration: nil, hooks: SplitURLSession.Hooks(), registry: .shared, sleep: { try await Task.sleep(for: $0) })
	}

	/// Creates a client whose downloads and uploads run on the background URL session of `sessionIdentifier`, and whose other requests run on a foreground URL session.
	static func background(tokenSource: TokenSource, sessionIdentifier: String, sharedContainerIdentifier: String?) -> Self {
		return Self(tokenSource: tokenSource, configuration: backgroundConfiguration(sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier), metadataConfiguration: foregroundConfiguration(), hooks: SplitURLSession.Hooks(), registry: .shared, sleep: { try await Task.sleep(for: $0) })
	}

	static func foregroundConfiguration() -> URLSessionConfiguration {
		return HTTPClientSupport.hardened(.default)
	}

	static func backgroundConfiguration(sessionIdentifier: String, sharedContainerIdentifier: String?) -> URLSessionConfiguration {
		return HTTPClientSupport.hardenedBackground(identifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
	}
}
