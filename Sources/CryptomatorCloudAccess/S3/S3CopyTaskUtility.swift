//
//  S3CopyTaskUtility.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 15.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import AWSS3
import Foundation
import Promises

class S3CopyTaskUtility {
	private let service: AWSS3
	private let bucket: String

	private let operationQueue: OperationQueue
	private let semaphore: DispatchSemaphore
	private let maxPartSize: Int
	// allowed maximum part size is 5GiB in multipart upload.
	private static let maxPartSize = 5 * 1024 * 1024 * 1024

	init(service: AWSS3, bucket: String, concurrencyLimit: Int = 4, maxPartSize: Int = S3CopyTaskUtility.maxPartSize) {
		self.service = service
		self.bucket = bucket
		self.semaphore = DispatchSemaphore(value: concurrencyLimit)
		self.maxPartSize = maxPartSize
		self.operationQueue = OperationQueue()
		operationQueue.maxConcurrentOperationCount = concurrencyLimit
	}

	func copy(_ request: S3CopyRequest) -> Promise<Void> {
		if request.itemSize > maxPartSize {
			return multipartCopy(request)
		} else {
			return regularCopy(request)
		}
	}

	private func regularCopy(_ request: S3CopyRequest) -> Promise<Void> {
		CloudAccessDDLogDebug("S3CopyTaskUtility: regularCopy(\(request)) called")
		let replicateRequest = AWSS3ReplicateObjectRequest()!
		replicateRequest.replicateSource = createReplicateSourceString(for: request.sourceKey, bucket: bucket)
		replicateRequest.bucket = bucket
		replicateRequest.key = request.targetKey
		return service.replicateObject(replicateRequest).then { output in
			CloudAccessDDLogDebug("S3CopyTaskUtility: regularCopy(\(request)) received output: \(output)")
		}
	}

	private func multipartCopy(_ request: S3CopyRequest) -> Promise<Void> {
		CloudAccessDDLogDebug("S3CopyTaskUtility: multipartCopy(\(request)) called")
		let uploadRequest = AWSS3CreateMultipartUploadRequest()!
		uploadRequest.key = request.targetKey
		uploadRequest.bucket = bucket
		return service.createMultipartUpload(uploadRequest).then {
			guard let uploadID = $0.uploadId else {
				return Promise(S3CopyTaskUtilityError.missingUploadID)
			}
			let requests = self.constructParts(for: $0, itemSize: request.itemSize, sourceKey: request.sourceKey)
			let subTasks = requests.map { S3MultiPartCopySubTask(request: $0) }
			let task = S3MultiPartCopyTask(subTasks: subTasks, bucket: self.bucket, key: request.targetKey, uploadID: uploadID)
			return self.execute(task)
		}.then {
			CloudAccessDDLogDebug("S3CopyTaskUtility: multipartCopy(\(request)) finished")
		}
	}

	private func execute(_ task: S3MultiPartCopyTask) -> Promise<Void> {
		let subTasks = task.subTasks.map {
			execute($0)
		}
		return all(subTasks).then { _ in
			self.completeTask(task)
		}.catch { _ in
			_ = self.abortTask(task)
		}
	}

	private func execute(_ subTask: S3MultiPartCopySubTask) -> Promise<Void> {
		CloudAccessDDLogDebug("S3CopyTaskUtility: execute(\(subTask.request.partNumber ?? -1)) called")
		let pendingPromise = Promise<Void>.pending()
		operationQueue.addOperation {
			self.semaphore.wait()
			pendingPromise.fulfill(())
		}
		return pendingPromise.then { _ -> Promise<AWSS3UploadPartCopyOutput> in
			return self.service.uploadPartCopy(subTask.request)
		}.then { output -> Void in
			CloudAccessDDLogDebug("S3CopyTaskUtility: execute(\(subTask.request.partNumber ?? -1)) received output: \(output)")
			subTask.eTag = output.replicatePartResult?.eTag
		}.always {
			self.semaphore.signal()
		}
	}

	private func completeTask(_ task: S3MultiPartCopyTask) -> Promise<Void> {
		CloudAccessDDLogDebug("S3CopyTaskUtility: completeTask(\(task.uploadID)) called")
		let completedParts: [AWSS3CompletedPart] = task.subTasks.compactMap {
			let completedPart = AWSS3CompletedPart()
			completedPart?.partNumber = $0.request.partNumber
			completedPart?.eTag = $0.eTag
			return completedPart
		}
		let multipartUpload = AWSS3CompletedMultipartUpload()!
		multipartUpload.parts = completedParts

		let completeRequest = AWSS3CompleteMultipartUploadRequest()!
		completeRequest.bucket = task.bucket
		completeRequest.key = task.key
		completeRequest.uploadId = task.uploadID
		completeRequest.multipartUpload = multipartUpload
		return service.completeMultipartUpload(completeRequest).then { output in
			CloudAccessDDLogDebug("S3CopyTaskUtility: completeTask(\(task.uploadID)) received output: \(output)")
		}
	}

	private func abortTask(_ task: S3MultiPartCopyTask) -> Promise<Void> {
		CloudAccessDDLogDebug("S3CopyTaskUtility: abortTask(\(task.uploadID)) called")
		let abortRequest = AWSS3AbortMultipartUploadRequest()!
		abortRequest.bucket = task.bucket
		abortRequest.uploadId = task.uploadID
		abortRequest.key = task.key
		return service.abortMultipartUpload(abortRequest).then { output in
			CloudAccessDDLogDebug("S3CopyTaskUtility: abortTask(\(task.uploadID)) received output: \(output)")
		}
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
			let endBytes: Int
			if remaining < maxPartSize {
				endBytes = startBytes + remaining
			} else {
				endBytes = startBytes + maxPartSize
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
		let subTasks: [S3MultiPartCopySubTask]
		let bucket: String
		let key: String
		let uploadID: String
	}

	private class S3MultiPartCopySubTask {
		var eTag: String?
		let request: AWSS3UploadPartCopyRequest

		init(eTag: String? = nil, request: AWSS3UploadPartCopyRequest) {
			self.eTag = eTag
			self.request = request
		}
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
