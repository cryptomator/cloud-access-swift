//
//  TLSCertificateValidator.swift
//  CloudAccess
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

public struct TestedCertificate {
	let data: Data
	let isTrusted: Bool
	let fingerprint: String
}

private extension Sequence where Element == UInt8 {
	func toHexString(separator: String = "") -> String {
		return map { String(format: "%02lx", $0) }.joined(separator: separator)
	}
}

private class TLSCertificateValidatorURLSessionDelegate: NSObject, URLSessionTaskDelegate {
	var testedCertificate: TestedCertificate?

	// MARK: - URLSessionDelegate

	func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust, let certificate = getCertificate(from: trust) {
			var trustResultType: SecTrustResultType = .invalid
			let isTrusted = SecTrustEvaluate(trust, &trustResultType) == errSecSuccess
			let fingerprint = calculateFingerprint(from: certificate)
			testedCertificate = TestedCertificate(data: certificate, isTrusted: isTrusted, fingerprint: fingerprint)
		}
		completionHandler(.cancelAuthenticationChallenge, nil)
	}

	// MARK: - URLSessionTaskDelegate

	func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		completionHandler(.cancelAuthenticationChallenge, nil)
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
}

public class TLSCertificateValidator {
	private let baseURL: URL
	private let urlSession: URLSession
	private let urlSessionDelegate: TLSCertificateValidatorURLSessionDelegate

	public init(baseURL: URL, sharedContainerIdentifier: String) {
		self.baseURL = baseURL
		self.urlSessionDelegate = TLSCertificateValidatorURLSessionDelegate()
		self.urlSession = TLSCertificateValidator.createURLSession(sharedContainerIdentifier: sharedContainerIdentifier, delegate: urlSessionDelegate)
	}

	private static func createURLSession(sharedContainerIdentifier: String, delegate: URLSessionDelegate) -> URLSession {
		let configuration = URLSessionConfiguration.background(withIdentifier: "CloudAccessTLSCertificateValidator_\(UUID().uuidString)")
		configuration.sharedContainerIdentifier = sharedContainerIdentifier
		configuration.httpCookieStorage = HTTPCookieStorage()
		return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
	}

	public func validate() -> Promise<TestedCertificate> {
		var request = URLRequest(url: baseURL)
		request.httpMethod = "GET"
		return urlSession.performDownloadTask(with: request).then { _, _ in
			if let testedCertificate = self.urlSessionDelegate.testedCertificate {
				return Promise(testedCertificate)
			} else {
				return Promise(TLSCertificateValidatorError.validationFailed)
			}
		}
	}
}
