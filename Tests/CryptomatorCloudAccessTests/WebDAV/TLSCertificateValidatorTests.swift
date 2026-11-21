//
//  TLSCertificateValidatorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct TLSCertificateValidatorTests {
		@Test
		func validateRethrowsConnectionError() async throws {
			let validator = try TLSCertificateValidator(baseURL: #require(URL(string: "https://127.0.0.1:1/")))
			let error = try await #require(throws: (any Error).self) { try await validator.validate() }
			let urlError = try #require(error as? URLError)
			#expect(urlError.code == .cannotConnectToHost)
			#expect(urlError.failingURL == nil)
		}

		@Test
		func leafCertificateDataIsServerCertificateOfChain() throws {
			// A certificate for webdav.example.com issued by a private CA, followed by that CA.
			let leafData = try #require(Data(base64Encoded: "MIIBdDCCARugAwIBAgIUUHtXtM2pDUKQi3+1FjkL6i9eFOgwCgYIKoZIzj0EAwIwEjEQMA4GA1UEAwwHVGVzdC1DQTAgFw0yNjEwMTgxNjIyMzdaGA8yMTI2MDkyNDE2MjIzN1owHTEbMBkGA1UEAwwSd2ViZGF2LmV4YW1wbGUuY29tMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8z0/nodn1zP9HMyHAfCoQXNg3lgLEVkAq8X6szqGLshti7oRpPxgSp/iehaEe2tacYlFMqDRMJ/qk/V+/3UfsqNCMEAwHQYDVR0OBBYEFISgjtfTT9vQ41GCxINYSdw6WGQzMB8GA1UdIwQYMBaAFOoM6urcDcvN2+vtSwmQ46A0uPNqMAoGCCqGSM49BAMCA0cAMEQCICbdjbz50rZk6GX8UVX/OEwkjQVbgbexZjPD8qhN0lBNAiBn61ncRQ5PabedIx3qsz0/8RiPJ2EBw44I0FUGnebKjg=="))
			let caData = try #require(Data(base64Encoded: "MIIBWjCCAQCgAwIBAgIUHr6cRB5NJSSh35U0a4wd+gHO6zMwCgYIKoZIzj0EAwIwEjEQMA4GA1UEAwwHVGVzdC1DQTAgFw0yNjEwMTgxNjIyMzdaGA8yMTI2MDkyNDE2MjIzN1owEjEQMA4GA1UEAwwHVGVzdC1DQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBIdRoQUr5IIMeckKSLkcjOZkyaDssibhbs6iygAhMzBwe21tUljM2t1kng9Hyp+3KRvMFM/g69u72luamy012WjMjAwMB0GA1UdDgQWBBTqDOrq3A3Lzdvr7UsJkOOgNLjzajAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQDONRcbKVC5ppYEhYyOmV/3zBbSz39CCAz8PLqEeeCOzQIgJK5X8ifUCQrtOerXHTYBgDFcqZeTXxIarT94d+H1H0Q="))
			let certificates = try [leafData, caData].map { try #require(SecCertificateCreateWithData(nil, $0 as CFData)) }
			var trust: SecTrust?
			#expect(errSecSuccess == SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, "webdav.example.com" as CFString), &trust))

			#expect(try leafData == #require(trust).leafCertificateData)
		}
	}
}
