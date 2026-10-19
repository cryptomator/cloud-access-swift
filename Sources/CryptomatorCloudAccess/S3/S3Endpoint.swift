//
//  S3Endpoint.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Builds the URLs of a bucket's requests.

 Only the scheme, host and port of the credential's URL are used, which is how AWS SDK 2.41.0 addressed its transfers. A bucket is addressed in the host (virtual-hosted style) if it passes the bucket name rule of AWS SDK 2.41.0 and contains only characters that are valid in a host. Any other bucket, and every bucket of an IPv6 host, is addressed in the path (path style).
 */
struct S3Endpoint: Sendable {
	private static let hostLabelCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

	private let scheme: String
	/// The percent-encoded host, which keeps the brackets of an IPv6 address.
	private let host: String
	private let port: Int?
	private let isVirtualHosted: Bool
	let bucket: String

	init(credential: S3Credential) {
		let scheme = credential.url.scheme?.lowercased() ?? "https"
		self.scheme = scheme
		self.host = URLComponents(url: credential.url, resolvingAgainstBaseURL: false)?.encodedHost ?? ""
		// An explicit default port is dropped, so that a stored `https://host:443` credential signs and sends the bare host, as AWS SDK 2.41.0 did.
		if let port = credential.url.port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) {
			self.port = port
		} else {
			self.port = nil
		}
		self.bucket = credential.bucket
		self.isVirtualHosted = S3Endpoint.isVirtualHostedStyleCompliant(bucket: credential.bucket) && credential.bucket.allSatisfy(S3Endpoint.hostLabelCharacters.contains) && !host.hasPrefix("[")
	}

	static func isVirtualHostedStyleCompliant(bucket: String) -> Bool {
		guard (3 ... 63).contains(bucket.count), !bucket.hasSuffix("-"), !bucket.contains("_"), !bucket.contains("-."), !bucket.contains(".-"), bucket.lowercased() == bucket else {
			return false
		}
		return !bucket.contains(".")
	}

	/// Returns the URL of the object with the given key, or of the bucket for an empty key. The query is sent percent-encoded exactly as it is signed.
	func url(forKey key: String, query: [URLQueryItem] = []) -> URL {
		var components = URLComponents()
		components.scheme = scheme
		components.port = port
		let encodedKey = S3Signer.encode(key, encodeSlash: false)
		if isVirtualHosted {
			components.encodedHost = "\(bucket).\(host)"
			components.percentEncodedPath = "/\(encodedKey)"
		} else {
			components.encodedHost = host
			components.percentEncodedPath = "/\(S3Signer.encode(bucket, encodeSlash: true))" + (key.isEmpty ? "" : "/\(encodedKey)")
		}
		if !query.isEmpty {
			components.percentEncodedQuery = query.map { item in
				let name = S3Signer.encode(item.name, encodeSlash: true)
				return item.value.map { "\(name)=\(S3Signer.encode($0, encodeSlash: true))" } ?? name
			}.joined(separator: "&")
		}
		guard let url = components.url else {
			preconditionFailure("A URL with a scheme, a host and an absolute path is valid")
		}
		return url
	}

	/// Returns the `x-amz-copy-source` header value that addresses the object with the given key.
	func copySource(forKey key: String) -> String {
		return "\(S3Signer.encode(bucket, encodeSlash: true))/\(S3Signer.encode(key, encodeSlash: false))"
	}
}
