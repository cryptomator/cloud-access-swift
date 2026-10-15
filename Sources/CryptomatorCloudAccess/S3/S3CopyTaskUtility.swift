//
//  S3CopyTaskUtility.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 15.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AWSS3
import Foundation

final class S3CopyTaskUtility: Sendable {
	private let service: AWSS3
	private let bucket: String

	private let concurrencyLimit: Int
	private let maxPartSize: Int
	/// allowed maximum part size is 5GiB in multipart upload.
	private static let maxPartSize = 5 * 1024 * 1024 * 1024

	init(service: AWSS3, bucket: String, concurrencyLimit: Int = 4, maxPartSize: Int = S3CopyTaskUtility.maxPartSize) {
		self.service = service
		self.bucket = bucket
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
		let replicateRequest = AWSS3ReplicateObjectRequest()!
		replicateRequest.replicateSource = createReplicateSourceString(for: request.sourceKey, bucket: bucket)
		replicateRequest.bucket = bucket
		replicateRequest.key = request.targetKey
		let output = try await service.executeReplicateObject(replicateRequest)
		CloudAccessDDLogDebug("S3CopyTaskUtility: regularCopy(\(request)) received output: \(output)")
	}

	private func multipartCopy(_ request: S3CopyRequest) async throws {
		CloudAccessDDLogDebug("S3CopyTaskUtility: multipartCopy(\(request)) called")
		let uploadRequest = AWSS3CreateMultipartUploadRequest()!
		uploadRequest.key = request.targetKey
		uploadRequest.bucket = bucket
		let multipartUpload = try await service.executeCreateMultipartUpload(uploadRequest)
		guard let uploadID = multipartUpload.uploadId else {
			throw S3CopyTaskUtilityError.missingUploadID
		}
		let requests = constructParts(for: multipartUpload, itemSize: request.itemSize, sourceKey: request.sourceKey)
		let task = S3MultiPartCopyTask(requests: requests, bucket: bucket, key: request.targetKey, uploadID: uploadID)
		try await execute(task)
		CloudAccessDDLogDebug("S3CopyTaskUtility: multipartCopy(\(request)) finished")
	}

	/// Aborts the multipart upload if it fails or is cancelled. The abort waits until the task group finished the parts that were already started, because S3 may keep a part that completes after the abort.
	private func execute(_ task: S3MultiPartCopyTask) async throws {
		do {
			let eTags = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
				var eTags = [String?](repeating: nil, count: task.requests.count)
				for (index, request) in task.requests.enumerated() {
					if index >= concurrencyLimit, let (finishedIndex, eTag) = try await group.next() {
						eTags[finishedIndex] = eTag
					}
					try Task.checkCancellation()
					group.addTask {
						return try await (index, self.execute(request))
					}
				}
				for try await (finishedIndex, eTag) in group {
					eTags[finishedIndex] = eTag
				}
				return eTags
			}
			try Task.checkCancellation()
			try await completeTask(task, eTags: eTags)
		} catch {
			try? await abortTask(task)
			throw error
		}
	}

	private func execute(_ request: AWSS3UploadPartCopyRequest) async throws -> String? {
		CloudAccessDDLogDebug("S3CopyTaskUtility: execute(\(request.partNumber ?? -1)) called")
		let output = try await service.executeUploadPartCopy(request)
		CloudAccessDDLogDebug("S3CopyTaskUtility: execute(\(request.partNumber ?? -1)) received output: \(output)")
		return output.replicatePartResult?.eTag
	}

	private func completeTask(_ task: S3MultiPartCopyTask, eTags: [String?]) async throws {
		CloudAccessDDLogDebug("S3CopyTaskUtility: completeTask(\(task.uploadID)) called")
		let completedParts: [AWSS3CompletedPart] = zip(task.requests, eTags).compactMap { request, eTag in
			let completedPart = AWSS3CompletedPart()
			completedPart?.partNumber = request.partNumber
			completedPart?.eTag = eTag
			return completedPart
		}
		let multipartUpload = AWSS3CompletedMultipartUpload()!
		multipartUpload.parts = completedParts

		let completeRequest = AWSS3CompleteMultipartUploadRequest()!
		completeRequest.bucket = task.bucket
		completeRequest.key = task.key
		completeRequest.uploadId = task.uploadID
		completeRequest.multipartUpload = multipartUpload
		let output = try await service.executeCompleteMultipartUpload(completeRequest)
		CloudAccessDDLogDebug("S3CopyTaskUtility: completeTask(\(task.uploadID)) received output: \(output)")
	}

	private func abortTask(_ task: S3MultiPartCopyTask) async throws {
		CloudAccessDDLogDebug("S3CopyTaskUtility: abortTask(\(task.uploadID)) called")
		let abortRequest = AWSS3AbortMultipartUploadRequest()!
		abortRequest.bucket = task.bucket
		abortRequest.uploadId = task.uploadID
		abortRequest.key = task.key
		let output = try await service.executeAbortMultipartUpload(abortRequest)
		CloudAccessDDLogDebug("S3CopyTaskUtility: abortTask(\(task.uploadID)) received output: \(output)")
	}

	private func constructParts(for multipartUpload: AWSS3CreateMultipartUploadOutput, itemSize: Int, sourceKey: String) -> [AWSS3UploadPartCopyRequest] {
		var parts = [AWSS3UploadPartCopyRequest]()
		var remaining = itemSize
		var offset = 0
		var partNumber = 1
		while remaining > 0 {
			let partCopyRequest = AWSS3UploadPartCopyRequest()!
			partCopyRequest.uploadId = multipartUpload.uploadId
			partCopyRequest.bucket = multipartUpload.bucket
			partCopyRequest.key = multipartUpload.key
			partCopyRequest.replicateSource = createReplicateSourceString(for: sourceKey, bucket: multipartUpload.bucket ?? "")
			partCopyRequest.partNumber = partNumber as NSNumber
			let startBytes = offset
			let endBytes: Int = if remaining < maxPartSize {
				startBytes + remaining
			} else {
				startBytes + maxPartSize
			}
			// The range of bytes to copy from the source object. The range value must use the form bytes=first-last, where the first and last are the zero-based byte offsets to copy. For example, bytes=0-9 indicates that you want to copy the first 10 bytes of the source. You can copy a range only if the source object is greater than 5 MB.
			partCopyRequest.replicateSourceRange = "bytes=\(startBytes)-\(endBytes - 1)"
			parts.append(partCopyRequest)
			partNumber += 1
			let length = endBytes - startBytes
			remaining -= length
			offset += length
		}
		return parts
	}

	private func createReplicateSourceString(for sourceKey: String, bucket: String) -> String? {
		"\(bucket)/\(sourceKey)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
	}

	private struct S3MultiPartCopyTask {
		let requests: [AWSS3UploadPartCopyRequest]
		let bucket: String
		let key: String
		let uploadID: String
	}
}

enum S3CopyTaskUtilityError: Error {
	case missingUploadID
}

struct S3CopyRequest {
	let sourceKey: String
	let targetKey: String
	let itemSize: Int
}
