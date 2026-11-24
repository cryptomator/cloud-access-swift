//
//  TLSCertificateValidator.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 02.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import Foundation

public enum TLSCertificateValidatorError: Error {
	case validationFailed
}

/// Cancels every challenge, which ends the request, and records the certificate of a server trust challenge.
private struct CertificateRecordingChallengeHandler: SplitURLSession.ChallengeHandler {
	/// The certificate that the server presented, passed as the decision's failure, because that is the only value a challenge handler can hand to the outcome of its request.
	struct PresentedCertificate: Error {
		let certificate: TLSCertificate
	}

	func decision(for challenge: URLAuthenticationChallenge, task: URLSessionTask) -> SplitURLSession.ChallengeDecision {
		guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust, let certificate = trust.leafCertificateData else {
			CloudAccessDDLogError("TLSCertificateValidator: failed to get certificate from received challenge.protectionSpace: \(challenge.protectionSpace)")
			return SplitURLSession.ChallengeDecision(disposition: .cancelAuthenticationChallenge, credential: nil, failure: nil)
		}
		let isTrusted = SecTrustEvaluateWithError(trust, nil)
		let fingerprint = SHA256.hash(data: certificate).hexEncodedString(separator: " ")
		let presentedCertificate = PresentedCertificate(certificate: TLSCertificate(data: certificate, isTrusted: isTrusted, fingerprint: fingerprint))
		return SplitURLSession.ChallengeDecision(disposition: .cancelAuthenticationChallenge, credential: nil, failure: presentedCertificate)
	}
}

public final class TLSCertificateValidator: Sendable {
	private let baseURL: URL
	private let session: SplitURLSession

	public init(baseURL: URL) {
		self.baseURL = baseURL
		self.session = SplitURLSession(configuration: HTTPClientSupport.hardened(.default), challengeHandler: CertificateRecordingChallengeHandler())
	}

	/**
	 Fetches the certificate that the server at `baseURL` presents.

	 - Throws: `TLSCertificateValidatorError.validationFailed` if no certificate was received. If the request failed before the server presented one, e.g., because the server can't be reached, the transport error instead, without the request's URL (a `URLError` keeps only its code).
	 */
	public func validate() async throws -> TLSCertificate {
		let outcome = try await session.data(URLRequest(url: baseURL), bodyLimit: 0, bodyLogging: .omitted)
		try Task.checkCancellation()
		if let presentedCertificate = outcome.recordedFailure as? CertificateRecordingChallengeHandler.PresentedCertificate {
			return presentedCertificate.certificate
		}
		// The handler cancels every challenge, so a cancelled request means that a challenge without a certificate was received.
		if let error = outcome.error, !isCancellationError(error) {
			throw error
		}
		throw TLSCertificateValidatorError.validationFailed
	}
}

extension SecTrust {
	/// The DER data of the server's own certificate, which `WebDAVCredential.allowedCertificate` pins.
	var leafCertificateData: Data? {
		guard let certificate = (SecTrustCopyCertificateChain(self) as? [SecCertificate])?.first else {
			return nil
		}
		return SecCertificateCopyData(certificate) as Data
	}
}
