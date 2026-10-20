//
//  S3Signer.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptoKit
import Foundation

/// Signs S3 requests with AWS Signature Version 4, either in the `Authorization` header or as a presigned URL.
struct S3Signer: Sendable {
	static let emptyPayloadHash = sha256Hex(Data())
	private static let unsignedPayload = "UNSIGNED-PAYLOAD"
	private static let algorithm = "AWS4-HMAC-SHA256"
	private static let service = "s3"

	/// The region names that AWS SDK 2.41.0 accepted for its regions besides their canonical names, e.g., `USEast1` and `AWSRegionUSEast1` for `us-east-1`. Stored credentials may contain them.
	private static let regionAliases: [String: String] = {
		let canonicalNames = [
			"USEast1": "us-east-1", "USEast2": "us-east-2", "USWest1": "us-west-1", "USWest2": "us-west-2",
			"EUWest1": "eu-west-1", "EUWest2": "eu-west-2", "EUWest3": "eu-west-3", "EUCentral1": "eu-central-1", "EUCentral2": "eu-central-2", "EUNorth1": "eu-north-1", "EUSouth1": "eu-south-1", "EUSouth2": "eu-south-2",
			"APNortheast1": "ap-northeast-1", "APNortheast2": "ap-northeast-2", "APSoutheast1": "ap-southeast-1", "APSoutheast2": "ap-southeast-2", "APSoutheast3": "ap-southeast-3", "APSoutheast4": "ap-southeast-4", "APSoutheast5": "ap-southeast-5", "APSoutheast7": "ap-southeast-7", "APSouth1": "ap-south-1", "APSouth2": "ap-south-2", "APEast1": "ap-east-1", "APEast2": "ap-east-2",
			"SAEast1": "sa-east-1", "CACentral1": "ca-central-1", "CAWest1": "ca-west-1", "USGovWest1": "us-gov-west-1", "USGovEast1": "us-gov-east-1",
			"CNNorth1": "cn-north-1", "CNNorthWest1": "cn-northwest-1", "MECentral1": "me-central-1", "MESouth1": "me-south-1", "AFSouth1": "af-south-1", "ILCentral1": "il-central-1", "MXCentral1": "mx-central-1"
		]
		return canonicalNames.reduce(into: [:]) { aliases, entry in
			aliases[entry.key] = entry.value
			aliases["AWSRegion\(entry.key)"] = entry.value
		}
	}()

	let accessKey: String
	let secretKey: String
	let region: String

	init(accessKey: String, secretKey: String, region: String) {
		self.accessKey = accessKey
		self.secretKey = secretKey
		self.region = region
	}

	init(credential: S3Credential) {
		self.init(accessKey: credential.accessKey, secretKey: credential.secretKey, region: S3Signer.signingRegion(for: credential.region))
	}

	/// Maps a region alias that AWS SDK 2.41.0 accepted to its canonical name, so that a stored credential keeps signing with the same region. Any other region is returned unchanged.
	static func signingRegion(for region: String) -> String {
		return regionAliases[region] ?? region
	}

	static func sha256Hex(_ data: Data) -> String {
		return hex(SHA256.hash(data: data))
	}

	// MARK: - Signing

	/// Signs the `host` and every header that is set on the request, and sets the `x-amz-date`, `x-amz-content-sha256` and `Authorization` headers.
	func sign(_ request: inout URLRequest, payloadHash: String, date: Date) {
		let dateTime = S3Signer.dateTime(for: date)
		request.setValue(dateTime, forHTTPHeaderField: "x-amz-date")
		request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
		guard let url = request.url else {
			return
		}
		let headers = S3Signer.canonicalHeaders(url: url, headers: request.allHTTPHeaderFields ?? [:])
		let signedHeaders = headers.map(\.name).joined(separator: ";")
		let signature = signature(method: request.httpMethod ?? "GET", url: url, headers: headers, payloadHash: payloadHash, dateTime: dateTime)
		request.setValue("\(S3Signer.algorithm) Credential=\(accessKey)/\(scope(dateTime: dateTime)), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
	}

	/// Returns the URL with the authentication parameters and the signature in its query. The request must send each of the given `headers` with its given value.
	func presignedURL(method: String, url: URL, headers: [String: String], expiresIn: Int, date: Date) -> URL {
		let dateTime = S3Signer.dateTime(for: date)
		let canonicalHeaders = S3Signer.canonicalHeaders(url: url, headers: headers)
		let authenticationParameters = [
			("X-Amz-Algorithm", S3Signer.algorithm),
			("X-Amz-Credential", "\(accessKey)/\(scope(dateTime: dateTime))"),
			("X-Amz-Date", dateTime),
			("X-Amz-Expires", String(expiresIn)),
			("X-Amz-SignedHeaders", canonicalHeaders.map(\.name).joined(separator: ";"))
		]
		let unsignedURL = url.appendingPercentEncodedQuery(authenticationParameters)
		let signature = signature(method: method, url: unsignedURL, headers: canonicalHeaders, payloadHash: S3Signer.unsignedPayload, dateTime: dateTime)
		return unsignedURL.appendingPercentEncodedQuery([("X-Amz-Signature", signature)])
	}

	// MARK: - Internal

	private func signature(method: String, url: URL, headers: [(name: String, value: String)], payloadHash: String, dateTime: String) -> String {
		let canonicalRequest = S3Signer.canonicalRequest(method: method, url: url, headers: headers, payloadHash: payloadHash)
		let stringToSign = [S3Signer.algorithm, dateTime, scope(dateTime: dateTime), S3Signer.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
		var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
		for component in [S3Signer.dateStamp(of: dateTime), region, S3Signer.service, "aws4_request"] {
			key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(component.utf8), using: key)))
		}
		return S3Signer.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
	}

	private func scope(dateTime: String) -> String {
		return "\(S3Signer.dateStamp(of: dateTime))/\(region)/\(S3Signer.service)/aws4_request"
	}

	static func canonicalRequest(method: String, url: URL, headers: [(name: String, value: String)], payloadHash: String) -> String {
		let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let path = components?.percentEncodedPath ?? ""
		let canonicalHeaders = headers.map { "\($0.name):\($0.value)\n" }.joined()
		let signedHeaders = headers.map(\.name).joined(separator: ";")
		return [method, path.isEmpty ? "/" : path, canonicalQuery(components?.percentEncodedQuery), canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
	}

	private static func canonicalQuery(_ percentEncodedQuery: String?) -> String {
		guard let percentEncodedQuery, !percentEncodedQuery.isEmpty else {
			return ""
		}
		return percentEncodedQuery.split(separator: "&").map { parameter -> (String, String) in
			let nameAndValue = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			let name = String(nameAndValue[0]).removingPercentEncoding ?? String(nameAndValue[0])
			let value = nameAndValue.count > 1 ? String(nameAndValue[1]).removingPercentEncoding ?? String(nameAndValue[1]) : ""
			return (HTTPClientSupport.percentEncoded(name, encodeSlash: true), HTTPClientSupport.percentEncoded(value, encodeSlash: true))
		}.sorted { $0 < $1 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
	}

	/// The signed `host` has to equal the `Host` header that URLSession sends: lowercased, with the brackets of an IPv6 address, and with the port whenever the URL has one, also a default one.
	static func canonicalHeaders(url: URL, headers: [String: String]) -> [(name: String, value: String)] {
		let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let host = (components?.encodedHost ?? "").lowercased() + (components?.port.map { ":\($0)" } ?? "")
		let otherHeaders = headers.map { (name: $0.key.lowercased(), value: $0.value.trimmingCharacters(in: .whitespaces)) }.filter { $0.name != "host" }
		return ([(name: "host", value: host)] + otherHeaders).sorted { $0.name < $1.name }
	}

	/// Returns the date in the basic ISO 8601 format, e.g., `20130524T000000Z`.
	private static func dateTime(for date: Date) -> String {
		return date.formatted(Date.ISO8601FormatStyle(dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted, timeZone: .gmt))
	}

	private static func dateStamp(of dateTime: String) -> String {
		return String(dateTime.prefix(8))
	}

	private static func hex(_ bytes: some Sequence<UInt8>) -> String {
		return bytes.map { String(format: "%02x", $0) }.joined()
	}
}

private extension URL {
	func appendingPercentEncodedQuery(_ parameters: [(String, String)]) -> URL {
		guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
			return self
		}
		let query = HTTPClientSupport.formEncoded(parameters)
		components.percentEncodedQuery = [components.percentEncodedQuery, query].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "&")
		return components.url ?? self
	}
}
