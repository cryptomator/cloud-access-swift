//
//  URLProtocolMock+Helpers.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

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

	/// The decoded value of the first query parameter of the name.
	static func queryParameter(_ name: String, of request: URLRequest) -> String? {
		return request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
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
	/**
	 Records the fraction of the progress when a transfer task terminated, which is before the provider completes the progress on its return.

	 - Parameter isExcluded: Whether an upload or download task isn't a transfer, e.g., a listing that is downloaded to a file.
	 */
	static func recordingTransferProgress(of progress: Progress, into fractions: OSAllocatedUnfairLock<[Double]>, excluding isExcluded: @escaping @Sendable (URLSessionTask) -> Bool = { _ in false }) -> SplitURLSession.Hooks {
		return SplitURLSession.Hooks(willProcessCompletion: { task in
			if task is URLSessionUploadTask || task is URLSessionDownloadTask, !isExcluded(task) {
				fractions.withLock { $0.append(progress.fractionCompleted) }
			}
		})
	}
}

/// Checks the fractions that `recordingTransferProgress` recorded for a transfer that ran in a single task.
func assertTransferProgress(_ fractions: [Double], _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
	assertTransferProgress(fractions, parts: [(length: 1, totalLength: 1)], comment, sourceLocation: sourceLocation)
}

/**
 Checks the fractions that `recordingTransferProgress` recorded for a transfer that ran in one task per part, the parts sending `length` bytes one after the other.

 More than half of each part's bytes must count towards the progress when its task terminates, and the progress must not complete before the transfer returns. `totalLength` is the byte count that the progress spans while the part is sent, which grows when the transfer sends bytes again.
 */
func assertTransferProgress(_ fractions: [Double], parts: [(length: Double, totalLength: Double)], _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
	let suffix = comment.map { " (\($0.rawValue))" } ?? ""
	#expect(fractions.count == parts.count, "Unexpected number of transfer tasks\(suffix)", sourceLocation: sourceLocation)
	var bytesBefore = 0.0
	for (index, (fraction, part)) in zip(fractions, parts).enumerated() {
		#expect(fraction > (bytesBefore + part.length / 2) / part.totalLength, "The progress of transfer task \(index) isn't part of the transfer's progress\(suffix)", sourceLocation: sourceLocation)
		#expect(fraction < 1, "The progress completed before transfer task \(index) returned\(suffix)", sourceLocation: sourceLocation)
		bytesBefore += part.length
	}
}

/// Checks the fractions that `recordingTransferProgress` recorded for a transfer that was retried once. The retry starts at half of the fraction that the first attempt reached, and the transfer ends where the first attempt did.
func assertRetryHalvesProgress(_ fractions: [Double], fractionAtRetry: Double?, sourceLocation: SourceLocation = #_sourceLocation) throws {
	#expect(fractions.count == 2, "Unexpected number of transfer tasks", sourceLocation: sourceLocation)
	let fractionAfterFirstAttempt = try #require(fractions.first, sourceLocation: sourceLocation)
	#expect(fractionAfterFirstAttempt > 0.5, sourceLocation: sourceLocation)
	let fractionAtRetry = try #require(fractionAtRetry, sourceLocation: sourceLocation)
	let fractionAfterLastAttempt = try #require(fractions.last, sourceLocation: sourceLocation)
	#expect(abs(fractionAfterFirstAttempt / 2 - fractionAtRetry) <= 0.01, sourceLocation: sourceLocation)
	#expect(abs(fractionAfterFirstAttempt - fractionAfterLastAttempt) <= 0.01, sourceLocation: sourceLocation)
}
