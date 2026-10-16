//
//  IntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Testing

/// Holds every suite that talks to a provider, so that the run scope sweeps before and cleans up after all of them.
@Suite(.integrationRun)
struct IntegrationTests {
	@Test
	func backendSelectionIsValid() {
		#expect(IntegrationBackend.invalidTokens.isEmpty, "Unknown INTEGRATION_BACKENDS tokens: \(IntegrationBackend.invalidTokens.joined(separator: ", ")). Valid tokens: \(IntegrationBackend.validTokens.joined(separator: ", "))")
		if IntegrationBackend.invalidTokens.isEmpty, !IntegrationBackend.selectsNone {
			#expect(!IntegrationBackend.selected.isEmpty, "INTEGRATION_BACKENDS selects no backend")
		}
	}
}

extension IntegrationTests {
	/// Holds the suites of provider-specific tests. Each is named after its `IntegrationProvider` raw value, in any case, followed by `Tests`, because `Scripts/run-integration-tests.sh` derives the provider token from the name.
	struct ProviderSpecific {}
}
