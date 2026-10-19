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

 The scheme, host, port and path of the credential's URL are used. A bucket is addressed in the host (virtual-hosted style) if it passes the bucket name rule of AWS SDK 2.41.0 and contains only characters that are valid in a host. Any other bucket, and every bucket of an IP address host, is addressed in the path (path style). As in the S3 endpoint rules of the AWS SDKs, the URL's path precedes the key in virtual-hosted style and the bucket in path style.
 */
struct S3Endpoint: Sendable {
	private static let hostLabelCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

	private let scheme: String
	/// The percent-encoded host, which keeps the brackets of an IPv6 address.
	private let host: String
	private let port: Int?
	/// The path of the credential's URL without a trailing slash. Each segment is decoded and re-encoded with the SigV4 rules, slash included, so that an escaped slash stays distinct from a separator. A segment that isn't valid percent-encoded UTF-8 is kept as it is.
	private let basePath: String
	private let isVirtualHosted: Bool
	let bucket: String

	/// - Throws: `URLError(.badURL)` if the credential's URL isn't an absolute HTTP or HTTPS URL with a host.
	init(credential: S3Credential) throws {
		let url = credential.url.absoluteURL
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = components.encodedHost, !host.isEmpty else {
			throw URLError(.badURL)
		}
		self.scheme = scheme
		self.host = host
		// An explicit default port is dropped, so that a stored `https://host:443` credential signs and sends the bare host, as AWS SDK 2.41.0 did.
		if let port = url.port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) {
			self.port = port
		} else {
			self.port = nil
		}
		var path = components.percentEncodedPath
		while path.hasSuffix("/") {
			path.removeLast()
		}
		self.basePath = path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
			segment.removingPercentEncoding.map { S3Signer.encode($0, encodeSlash: true) } ?? String(segment)
		}.joined(separator: "/")
		self.bucket = credential.bucket
		self.isVirtualHosted = S3Endpoint.isVirtualHostedStyleCompliant(bucket: credential.bucket) && credential.bucket.allSatisfy(S3Endpoint.hostLabelCharacters.contains) && !S3Endpoint.isIPAddress(host)
	}

	/// Whether the host is an IPv6 address in brackets or a string that URLSession connects to as an IPv4 address. `inet_aton` covers the short, hex and octal forms such as `127.1`, and `inet_pton` covers dotted quads with a zero-padded `08` or `09`, which `inet_aton` reads as invalid octal.
	private static func isIPAddress(_ host: String) -> Bool {
		var address = in_addr()
		return host.hasPrefix("[") || inet_aton(host, &address) == 1 || inet_pton(AF_INET, host, &address) == 1
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
			components.percentEncodedPath = "\(basePath)/\(encodedKey)"
		} else {
			components.encodedHost = host
			components.percentEncodedPath = "\(basePath)/\(S3Signer.encode(bucket, encodeSlash: true))" + (key.isEmpty ? "" : "/\(encodedKey)")
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
