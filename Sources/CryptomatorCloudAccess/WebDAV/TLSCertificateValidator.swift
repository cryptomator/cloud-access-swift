//
//  TLSCertificateValidator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 02.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CommonCrypto
import Foundation
import Promises

public enum TLSCertificateValidatorError: Error {
	case validationFailed
}

private extension Sequence where Element == UInt8 {
	func toHexString(separator: String = "") -> String {
		return map { String(format: "%02lx", $0) }.joined(separator: separator)
	}
}

private class TLSCertificateValidatorURLSessionDelegate: NSObject, URLSessionTaskDelegate {
	var testedCertificate: TLSCertificate?

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
		var digest = [UInt8](repeating: 0x00, count: Int(CC_SHA1_DIGEST_LENGTH))
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

	public func validate() -> Promise<TLSCertificate> {
		var request = URLRequest(url: baseURL)
		request.httpMethod = "GET"
		let pending = Promise<TLSCertificate>.pending()
		urlSession.performDownloadTask(with: request).always {
			if let testedCertificate = self.urlSessionDelegate?.testedCertificate {
				pending.fulfill(testedCertificate)
			} else {
				pending.reject(TLSCertificateValidatorError.validationFailed)
			}
		}
		return pending
	}
}
