//
//  TLSCertificateValidator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 02.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import Foundation
import os

public enum TLSCertificateValidatorError: Error {
	case validationFailed
}

private final class TLSCertificateValidatorURLSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
	private let lockedTestedCertificate = OSAllocatedUnfairLock<TLSCertificate?>(initialState: nil)
	var testedCertificate: TLSCertificate? {
		get { lockedTestedCertificate.withLock { $0 } }
		set { lockedTestedCertificate.withLock { $0 = newValue } }
	}

	// MARK: - URLSessionDelegate

	func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		handleChallenge(challenge, completionHandler: completionHandler)
	}

	// MARK: - URLSessionTaskDelegate

	func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		handleChallenge(challenge, completionHandler: completionHandler)
	}

	// MARK: - Internal

	private func calculateFingerprint(from certificate: Data) -> String {
		return SHA256.hash(data: certificate).hexEncodedString(separator: " ")
	}

	private func handleChallenge(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust, let certificate = trust.leafCertificateData {
			let isTrusted = SecTrustEvaluateWithError(trust, nil)
			let fingerprint = calculateFingerprint(from: certificate)
			testedCertificate = TLSCertificate(data: certificate, isTrusted: isTrusted, fingerprint: fingerprint)
		} else {
			CloudAccessDDLogError("TLSCertificateValidator: failed to get certificate from received challenge.protectionSpace: \(challenge.protectionSpace)")
		}
		completionHandler(.cancelAuthenticationChallenge, nil)
	}
}

public final class TLSCertificateValidator: Sendable {
	private let baseURL: URL
	private let urlSession: URLSession
	private let urlSessionDelegate: TLSCertificateValidatorURLSessionDelegate

	public init(baseURL: URL) {
		self.baseURL = baseURL
		let urlSessionDelegate = TLSCertificateValidatorURLSessionDelegate()
		self.urlSession = TLSCertificateValidator.createURLSession(delegate: urlSessionDelegate)
		self.urlSessionDelegate = urlSessionDelegate
	}

	deinit {
		urlSession.invalidateAndCancel()
	}

	private static func createURLSession(delegate: URLSessionDelegate) -> URLSession {
		return URLSession(configuration: HTTPClientSupport.hardened(.default), delegate: delegate, delegateQueue: nil)
	}

	/**
	 Fetches the certificate that the server at `baseURL` presents.

	 - Throws: The transport error if the request failed before the server presented a certificate, e.g., because the server can't be reached. Otherwise, `TLSCertificateValidatorError.validationFailed` if no certificate was received.
	 */
	public func validate() async throws -> TLSCertificate {
		var request = URLRequest(url: baseURL)
		request.httpMethod = "GET"
		var transportError: Error?
		do {
			let (location, _) = try await urlSession.download(for: request)
			try? FileManager.default.removeItem(at: location)
		} catch {
			transportError = error
		}
		try Task.checkCancellation()
		guard let testedCertificate = urlSessionDelegate.testedCertificate else {
			// The delegate cancels every challenge, so a cancelled request means that a challenge without a certificate was received.
			if let transportError, !isCancellationError(transportError) {
				throw transportError
			}
			throw TLSCertificateValidatorError.validationFailed
		}
		return testedCertificate
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
