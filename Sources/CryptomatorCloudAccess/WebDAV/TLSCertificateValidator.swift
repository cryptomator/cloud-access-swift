//
//  TLSCertificateValidator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 02.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CommonCrypto
import Foundation
import os

public enum TLSCertificateValidatorError: Error {
	case validationFailed
}

private extension Sequence<UInt8> {
	func toHexString(separator: String = "") -> String {
		return map { String(format: "%02lx", $0) }.joined(separator: separator)
	}
}

private final class TLSCertificateValidatorURLSessionDelegate: NSObject, URLSessionTaskDelegate {
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

	private func getCertificate(from trust: SecTrust) -> Data? {
		guard SecTrustGetCertificateCount(trust) > 0, let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
			return nil
		}
		return SecCertificateCopyData(certificate) as Data
	}

	private func calculateFingerprint(from certificate: Data) -> String {
		let bytes = [UInt8](certificate)
		var digest = [UInt8](repeating: 0x00, count: Int(CC_SHA256_DIGEST_LENGTH))
		CC_SHA256(bytes, UInt32(bytes.count) as CC_LONG, &digest)
		return digest.toHexString(separator: " ")
	}

	private func handleChallenge(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust, let certificate = getCertificate(from: trust) {
			let isTrusted = SecTrustEvaluateWithError(trust, nil)
			let fingerprint = calculateFingerprint(from: certificate)
			testedCertificate = TLSCertificate(data: certificate, isTrusted: isTrusted, fingerprint: fingerprint)
		} else {
			CloudAccessDDLogError("TLSCertificateValidator: failed to get certificate from received challenge.protectionSpace: \(challenge.protectionSpace)")
		}
		completionHandler(.cancelAuthenticationChallenge, nil)
	}
}

public class TLSCertificateValidator {
	private let baseURL: URL
	private let urlSession: URLSession
	private weak var urlSessionDelegate: TLSCertificateValidatorURLSessionDelegate?

	public init(baseURL: URL) {
		self.baseURL = baseURL
		let urlSessionDelegate = TLSCertificateValidatorURLSessionDelegate()
		self.urlSession = TLSCertificateValidator.createURLSession(delegate: urlSessionDelegate)
		self.urlSessionDelegate = urlSessionDelegate
	}

	private static func createURLSession(delegate: URLSessionDelegate) -> URLSession {
		let configuration = URLSessionConfiguration.default
		configuration.httpCookieStorage = HTTPCookieStorage()
		return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
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
		guard let testedCertificate = urlSessionDelegate?.testedCertificate else {
			// The delegate cancels every challenge, so a cancelled request means that a challenge without a certificate was received.
			if let transportError, !isCancellationError(transportError) {
				throw transportError
			}
			throw TLSCertificateValidatorError.validationFailed
		}
		return testedCertificate
	}
}
