//
//  S3CopyTaskUtility.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 15.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

final class S3CopyTaskUtility: Sendable {
	private let client: S3Client

	private let concurrencyLimit: Int
	private let maxPartSize: Int
	/// allowed maximum part size is 5GiB in multipart upload.
	private static let maxPartSize = 5 * 1024 * 1024 * 1024

	init(client: S3Client, concurrencyLimit: Int = 4, maxPartSize: Int = S3CopyTaskUtility.maxPartSize) {
		self.client = client
		self.concurrencyLimit = concurrencyLimit
		self.maxPartSize = maxPartSize
	}

	/// A multipart copy checks for cancellation before each part and before completing it. When a provider calls it after its commit point, these checks never fire, because that task isn't cancelled.
	func copy(_ request: S3CopyRequest) async throws {
		if request.itemSize > maxPartSize {
			try await multipartCopy(request)
		} else {
			try await regularCopy(request)
		}
	}

	private func regularCopy(_ request: S3CopyRequest) async throws {
		CloudAccessDDLogDebug("S3CopyTaskUtility: regularCopy(\(request)) called")
		try await client.copyObject(sourceKey: request.sourceKey, targetKey: request.targetKey)
		CloudAccessDDLogDebug("S3CopyTaskUtility: regularCopy(\(request)) finished")
	}

	private func multipartCopy(_ request: S3CopyRequest) async throws {
		CloudAccessDDLogDebug("S3CopyTaskUtility: multipartCopy(\(request)) called")
		let uploadID = try await client.createMultipartUpload(key: request.targetKey)
		let parts = constructParts(itemSize: request.itemSize)
		let task = S3MultiPartCopyTask(parts: parts, sourceKey: request.sourceKey, key: request.targetKey, uploadID: uploadID)
		try await execute(task)
		CloudAccessDDLogDebug("S3CopyTaskUtility: multipartCopy(\(request)) finished")
	}

	/// Aborts the multipart upload if it fails or is cancelled. The abort waits until the task group finished the parts that were already started, because S3 may keep a part that completes after the abort. The abort runs without cancellation, so that its retries after a transient failure still run when the copy was cancelled.
	private func execute(_ task: S3MultiPartCopyTask) async throws {
		do {
			let completedParts = try await withThrowingTaskGroup(of: S3CompletedPart.self) { group in
				var completedParts = [S3CompletedPart]()
				for (index, part) in task.parts.enumerated() {
					if index >= concurrencyLimit, let completedPart = try await group.next() {
						completedParts.append(completedPart)
					}
					try Task.checkCancellation()
					group.addTask {
						return try await (part.partNumber, self.execute(part, of: task))
					}
				}
				for try await completedPart in group {
					completedParts.append(completedPart)
				}
				return completedParts.sorted { $0.partNumber < $1.partNumber }
			}
			try Task.checkCancellation()
			try await completeTask(task, parts: completedParts)
		} catch {
			try? await withoutCancellation {
				try await self.abortTask(task)
			}
			throw error
		}
	}

	private func execute(_ part: S3CopyPart, of task: S3MultiPartCopyTask) async throws -> String {
		CloudAccessDDLogDebug("S3CopyTaskUtility: execute(\(part.partNumber)) called")
		let eTag = try await client.uploadPartCopy(sourceKey: task.sourceKey, range: part.range, key: task.key, uploadID: task.uploadID, partNumber: part.partNumber)
		CloudAccessDDLogDebug("S3CopyTaskUtility: execute(\(part.partNumber)) finished")
		return eTag
	}

	private func completeTask(_ task: S3MultiPartCopyTask, parts: [S3CompletedPart]) async throws {
		CloudAccessDDLogDebug("S3CopyTaskUtility: completeTask(\(task.uploadID)) called")
		try await client.completeMultipartUpload(key: task.key, uploadID: task.uploadID, parts: parts)
		CloudAccessDDLogDebug("S3CopyTaskUtility: completeTask(\(task.uploadID)) finished")
	}

	private func abortTask(_ task: S3MultiPartCopyTask) async throws {
		CloudAccessDDLogDebug("S3CopyTaskUtility: abortTask(\(task.uploadID)) called")
		try await client.abortMultipartUpload(key: task.key, uploadID: task.uploadID)
		CloudAccessDDLogDebug("S3CopyTaskUtility: abortTask(\(task.uploadID)) finished")
	}

	private func constructParts(itemSize: Int) -> [S3CopyPart] {
		var parts = [S3CopyPart]()
		var remaining = itemSize
		var offset = 0
		var partNumber = 1
		while remaining > 0 {
			let startBytes = offset
			let endBytes: Int = if remaining < maxPartSize {
				startBytes + remaining
			} else {
				startBytes + maxPartSize
			}
			// The range of bytes to copy from the source object. The range value must use the form bytes=first-last, where the first and last are the zero-based byte offsets to copy. For example, bytes=0-9 indicates that you want to copy the first 10 bytes of the source. You can copy a range only if the source object is greater than 5 MB.
			parts.append(S3CopyPart(partNumber: partNumber, range: "bytes=\(startBytes)-\(endBytes - 1)"))
			partNumber += 1
			let length = endBytes - startBytes
			remaining -= length
			offset += length
		}
		return parts
	}

	private struct S3CopyPart {
		let partNumber: Int
		let range: String
	}

	private struct S3MultiPartCopyTask {
		let parts: [S3CopyPart]
		let sourceKey: String
		let key: String
		let uploadID: String
	}
}

struct S3CopyRequest {
	let sourceKey: String
	let targetKey: String
	let itemSize: Int
}
