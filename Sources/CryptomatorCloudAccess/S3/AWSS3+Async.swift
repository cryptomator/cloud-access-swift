//
//  AWSS3+Async.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 15.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AWSCore
@preconcurrency import AWSS3
import Foundation

/// The `execute` prefix keeps these apart from the async methods of the same name that Swift imports for the completion handler methods, which wouldn't issue the request on the main actor.
extension AWSS3 {
	func executeListObjectsV2(_ request: AWSS3ListObjectsV2Request) async throws -> AWSS3ListObjectsV2Output {
		return try await execute { self.listObjectsV2(request, completionHandler: $0) }
	}

	func executeDeleteObject(_ request: AWSS3DeleteObjectRequest) async throws -> AWSS3DeleteObjectOutput {
		return try await execute { self.deleteObject(request, completionHandler: $0) }
	}

	func executePutObject(_ request: AWSS3PutObjectRequest) async throws -> AWSS3PutObjectOutput {
		return try await execute { self.putObject(request, completionHandler: $0) }
	}

	func executeDeleteObjects(_ request: AWSS3DeleteObjectsRequest) async throws -> AWSS3DeleteObjectsOutput {
		return try await execute { self.deleteObjects(request, completionHandler: $0) }
	}

	func executeCreateMultipartUpload(_ request: AWSS3CreateMultipartUploadRequest) async throws -> AWSS3CreateMultipartUploadOutput {
		return try await execute { self.createMultipartUpload(request, completionHandler: $0) }
	}

	func executeUploadPartCopy(_ request: AWSS3UploadPartCopyRequest) async throws -> AWSS3UploadPartCopyOutput {
		return try await execute { self.uploadPartCopy(request, completionHandler: $0) }
	}

	func executeAbortMultipartUpload(_ request: AWSS3AbortMultipartUploadRequest) async throws -> AWSS3AbortMultipartUploadOutput {
		return try await execute { self.abortMultipartUpload(request, completionHandler: $0) }
	}

	func executeCompleteMultipartUpload(_ request: AWSS3CompleteMultipartUploadRequest) async throws -> AWSS3CompleteMultipartUploadOutput {
		return try await execute { self.completeMultipartUpload(request, completionHandler: $0) }
	}

	func executeReplicateObject(_ request: AWSS3ReplicateObjectRequest) async throws -> AWSS3ReplicateObjectOutput {
		return try await execute { self.replicateObject(request, completionHandler: $0) }
	}

	private func execute<Output: Sendable>(_ call: @escaping @Sendable (@escaping @Sendable (Output?, Error?) -> Void) -> Void) async throws -> Output {
		return try await withMainActorSDKContinuation { resumer in
			call { output, error in
				if let output {
					resumer.resume(returning: output)
				} else {
					resumer.resume(throwing: convertAWSError(error))
				}
			}
		}
	}
}

extension AWSS3TransferUtility {
	func uploadFile(_ fileURL: URL, key: String, contentType: String, expression: AWSS3TransferUtilityUploadExpression?) async throws {
		try await withMainActorSDKContinuation { (resumer: Resumer<Void>) in
			self.uploadFile(fileURL, key: key, contentType: contentType, expression: expression) { _, error in
				if let error {
					resumer.resume(throwing: convertAWSError(error))
				} else {
					resumer.resume()
				}
			}.continueWith { task in
				// the completion handler is never called if the transfer couldn't be started
				if let error = task.error {
					resumer.resume(throwing: convertAWSError(error))
				}
				return nil
			}
		}
	}

	func download(to fileURL: URL, key: String, expression: AWSS3TransferUtilityDownloadExpression?) async throws {
		try await withMainActorSDKContinuation { (resumer: Resumer<Void>) in
			self.download(to: fileURL, key: key, expression: expression) { _, _, _, error in
				if let error {
					resumer.resume(throwing: convertAWSError(error))
				} else {
					resumer.resume()
				}
			}.continueWith { task in
				// the completion handler is never called if the transfer couldn't be started
				if let error = task.error {
					resumer.resume(throwing: convertAWSError(error))
				}
				return nil
			}
		}
	}
}

/**
 Converts the error that the AWS SDK reported for a request, so that every cancellation surfaces as `CancellationError`.

 - Parameter error: The reported error, or `nil` if the SDK reported neither a result nor an error, which is how a cancelled `AWSTask` completes.
 */
func convertAWSError(_ error: Error?) -> Error {
	guard let error else {
		return CancellationError()
	}
	let nsError = error as NSError
	if isCancellationError(error) || (nsError.domain == AWSNetworkingErrorDomain && nsError.code == AWSNetworkingErrorType.cancelled.rawValue) {
		return CancellationError()
	}
	return error
}
