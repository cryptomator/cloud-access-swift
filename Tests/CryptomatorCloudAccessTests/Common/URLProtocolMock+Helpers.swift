//
//  URLProtocolMock+Helpers.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

extension URLProtocolMock {
	static func formParameters(of request: URLRequest) -> [String: String] {
		return parameters(inFormEncoded: String(bytes: body(of: request), encoding: .utf8) ?? "")
	}

	static func parameters(inFormEncoded string: String) -> [String: String] {
		let pairs = string.split(separator: "&").map { pair in
			let nameAndValue = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
			return (nameAndValue[0], nameAndValue.count > 1 ? nameAndValue[1] : "")
		}
		return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
	}
}

/// Records the requests that reach `URLProtocolMock`, with their bodies.
final class RequestRecorder: Sendable {
	private let recordedRequests = OSAllocatedUnfairLock(initialState: [URLRequest]())

	var requests: [URLRequest] {
		return recordedRequests.withLock { $0 }
	}

	var record: @Sendable (URLRequest) -> Void {
		return { request in
			var recordedRequest = request
			recordedRequest.httpBody = URLProtocolMock.body(of: request)
			self.recordedRequests.withLock { [recordedRequest] in $0.append(recordedRequest) }
		}
	}
}

extension SplitURLSession.Hooks {
	/// Records the fraction of the progress when a transfer task terminated, which is before the provider completes the progress on its return.
	static func recordingTransferProgress(of progress: Progress, into fractions: OSAllocatedUnfairLock<[Double]>) -> SplitURLSession.Hooks {
		return SplitURLSession.Hooks(willProcessCompletion: { task in
			if task is URLSessionUploadTask || task is URLSessionDownloadTask {
				fractions.withLock { $0.append(progress.fractionCompleted) }
			}
		})
	}
}
