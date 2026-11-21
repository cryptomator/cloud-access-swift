//
//  RecordingURLProtocolMocks.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

/// The requests that reached a recording mock, in arrival order.
final class RequestLog: Sendable {
	private let recordedRequests = OSAllocatedUnfairLock(initialState: [URLRequest]())

	var requests: [URLRequest] {
		return recordedRequests.withLock { $0 }
	}

	var wireSummaries: [String] {
		return requests.map(\.wireSummary)
	}

	func append(_ request: URLRequest) {
		recordedRequests.withLock { $0.append(request) }
	}

	func reset() {
		recordedRequests.withLock { $0 = [] }
	}
}

/// Logs every request before `URLProtocolMock` answers it, including one that no handler is queued for.
final class RecordingURLProtocolMock: URLProtocolMock {
	static let log = RequestLog()

	override func startLoading() {
		RecordingURLProtocolMock.log.append(request)
		super.startLoading()
	}
}

/// Logs every request before `URLProtocolAuthenticationMock` challenges it, including one that no challenge is queued for.
final class RecordingURLProtocolAuthenticationMock: URLProtocolAuthenticationMock {
	static let log = RequestLog()

	override func startLoading() {
		RecordingURLProtocolAuthenticationMock.log.append(request)
		super.startLoading()
	}
}

extension URLRequest {
	/// The method, the `Depth` and `Overwrite` headers, the percent-encoded path as sent and the `Destination` header, each header only if the request has it, e.g. `MOVE Overwrite F /webdav/a.txt -> https://example.com/webdav/b.txt`.
	var wireSummary: String {
		var parts = [httpMethod ?? ""]
		if let depth = value(forHTTPHeaderField: "Depth") {
			parts.append("Depth \(depth)")
		}
		if let overwrite = value(forHTTPHeaderField: "Overwrite") {
			parts.append("Overwrite \(overwrite)")
		}
		parts.append(url?.path(percentEncoded: true) ?? "")
		if let destination = value(forHTTPHeaderField: "Destination") {
			parts.append("-> \(destination)")
		}
		return parts.joined(separator: " ")
	}
}
