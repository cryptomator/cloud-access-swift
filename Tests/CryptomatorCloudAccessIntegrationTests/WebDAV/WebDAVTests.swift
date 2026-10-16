//
//  WebDAVTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 12.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Testing

extension IntegrationTests.ProviderSpecific {
	@Suite(.enabled(if: IntegrationBackend.isSelected(.webDAV)))
	struct WebDAVTests {
		@Test(.enabled(if: IntegrationTestSecrets.webDAVCredential.baseURL.scheme == "https", "The WebDAV server is not reached via TLS"))
		func tlsCertificateValidatorReturnsServerCertificate() async throws {
			try await withIntegrationRetries(on: .webDAV) {
				let certificate = try await TLSCertificateValidator(baseURL: IntegrationTestSecrets.webDAVCredential.baseURL).validate()
				#expect(!certificate.data.isEmpty)
				#expect(certificate.fingerprint.split(separator: " ").count == 32)
			}
		}
	}
}
