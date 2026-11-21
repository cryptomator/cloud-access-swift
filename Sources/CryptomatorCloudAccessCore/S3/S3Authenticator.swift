//
//  S3Authenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

public enum S3Authenticator {
	/// The failures of a virtual-hosted request after which the bucket is listed in path style, because the server may not resolve or have a certificate for the bucket's host.
	private static let pathStyleFallbackErrorCodes: Set<URLError.Code> = [.cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot]

	/**
	 Verifies the credential by listing its bucket, and returns the credential that listed it, which the caller stores instead of the given one.

	 If the server names another region for the bucket, the bucket is listed once more in that region, on an AWS host also moved to that region. If the bucket's host can't be resolved or a TLS connection to it fails, the bucket is listed once more in path style. The returned credential carries these corrections, and equals the given one if none was needed.

	 - Throws: `URLError(.badURL)` if the credential's URL isn't an absolute HTTP or HTTPS URL with a host, `CancellationError` if the task is cancelled, and otherwise the failure of the last listing, converted like the errors of `S3CloudProvider`, e.g., `CloudProviderError.unauthorized` for a rejected secret key. If the path-style listing right after a DNS or TLS failure fails for another reason than a wrong region, that DNS or TLS failure is thrown instead, converted the same way.
	 */
	public static func verifyCredential(_ credential: S3Credential) async throws -> S3Credential {
		return try await verifyCredential(credential, makeClient: S3Client.foreground(credential:))
	}

	static func verifyCredential(_ credential: S3Credential, makeClient: (S3Credential) throws -> S3Client) async throws -> S3Credential {
		// The first attempt of a request is sent even in a cancelled task.
		try Task.checkCancellation()
		var candidate = credential
		var client = try makeClient(candidate)
		let provider = S3CloudProvider(client: client, maxPageSize: .max)
		var hasCorrectedRegion = false
		// The failure that led to the path-style listing, while that listing is the last attempt. The fallback runs at most once, because no later candidate is virtual-hosted.
		var pathStyleFallbackTrigger: Error?
		while true {
			let failure: Error
			do {
				_ = try await client.listObjectsV2(prefix: "", delimiter: "/", continuationToken: nil, maxKeys: 1)
				return candidate
			} catch {
				failure = error
			}
			if failure is CancellationError {
				throw failure
			}
			let next: S3Credential
			if !hasCorrectedRegion, let s3Error = failure as? S3Error, let corrected = regionCorrected(candidate, after: s3Error) {
				hasCorrectedRegion = true
				pathStyleFallbackTrigger = nil
				next = corrected
			} else if let urlError = failure as? URLError, pathStyleFallbackErrorCodes.contains(urlError.code), client.endpoint.isVirtualHosted {
				pathStyleFallbackTrigger = failure
				next = candidate.replacing(forcePathStyle: true)
			} else {
				// The client doesn't check for cancellation before it throws a failure that it doesn't retry, so a cancelled verification throws `CancellationError` here.
				try Task.checkCancellation()
				// A failure of the path-style request other than a wrong region says nothing about the cause, e.g., a server that only serves virtual-hosted requests may answer it with 403.
				if let pathStyleFallbackTrigger, (failure as? S3Error)?.isWrongRegion != true {
					throw provider.convertStandardError(pathStyleFallbackTrigger)
				}
				throw provider.convertStandardError(failure)
			}
			try Task.checkCancellation()
			candidate = next
			client = try makeClient(candidate)
		}
	}

	/// Returns the credential in the bucket region that a wrong-region error names, on an AWS host also moved to that region, or `nil` if the error is of another kind or names no region, or if the credential already signs in that region on that host.
	private static func regionCorrected(_ credential: S3Credential, after error: S3Error) -> S3Credential? {
		guard error.isWrongRegion, let bucketRegion = error.bucketRegion else {
			return nil
		}
		let corrected = credential.replacing(url: S3Endpoint.relocatedURL(credential.url, toRegion: bucketRegion) ?? credential.url, region: bucketRegion)
		guard S3Signer.signingRegion(for: corrected.region) != S3Signer.signingRegion(for: credential.region) || corrected.url != credential.url else {
			return nil
		}
		return corrected
	}
}

private extension S3Credential {
	func replacing(url: URL? = nil, region: String? = nil, forcePathStyle: Bool? = nil) -> S3Credential {
		return S3Credential(accessKey: accessKey, secretKey: secretKey, url: url ?? self.url, bucket: bucket, region: region ?? self.region, forcePathStyle: forcePathStyle ?? self.forcePathStyle, identifier: identifier)
	}
}
