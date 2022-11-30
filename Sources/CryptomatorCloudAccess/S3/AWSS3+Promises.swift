//
//  AWSS3+Promises.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 15.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import AWSS3
import Foundation
import Promises

extension AWSS3 {
	func listObjectsV2(_ request: AWSS3ListObjectsV2Request) -> Promise<AWSS3ListObjectsV2Output> {
		return wrap {
			self.listObjectsV2(request, completionHandler: $0)
		}.then {
			$0!
		}
	}

	func deleteObject(_ request: AWSS3DeleteObjectRequest) -> Promise<AWSS3DeleteObjectOutput> {
		return wrap {
			self.deleteObject(request, completionHandler: $0)
		}.then {
			$0!
		}
	}

	func putObject(_ request: AWSS3PutObjectRequest) -> Promise<AWSS3PutObjectOutput> {
		return wrap {
			self.putObject(request, completionHandler: $0)
		}.then {
			$0!
		}
	}

	func deleteObjects(_ request: AWSS3DeleteObjectsRequest) -> Promise<AWSS3DeleteObjectsOutput> {
		return wrap {
			self.deleteObjects(request, completionHandler: $0)
		}.then {
			$0!
		}
	}

	func createMultipartUpload(_ request: AWSS3CreateMultipartUploadRequest) -> Promise<AWSS3CreateMultipartUploadOutput> {
		return wrap {
			self.createMultipartUpload(request, completionHandler: $0)
		}.then {
			$0!
		}
	}

	func uploadPartCopy(_ request: AWSS3UploadPartCopyRequest) -> Promise<AWSS3UploadPartCopyOutput> {
		return wrap {
			self.uploadPartCopy(request, completionHandler: $0)
		}.then {
			$0!
		}
	}

	func abortMultipartUpload(_ request: AWSS3AbortMultipartUploadRequest) -> Promise<AWSS3AbortMultipartUploadOutput> {
		return wrap {
			self.abortMultipartUpload(request, completionHandler: $0)
		}.then {
			$0!
		}
	}

	func completeMultipartUpload(_ request: AWSS3CompleteMultipartUploadRequest) -> Promise<AWSS3CompleteMultipartUploadOutput> {
		return wrap {
			self.completeMultipartUpload(request, completionHandler: $0)
		}.then {
			$0!
		}
	}

	func replicateObject(_ request: AWSS3ReplicateObjectRequest) -> Promise<AWSS3ReplicateObjectOutput> {
		return wrap {
			self.replicateObject(request, completionHandler: $0)
		}.then {
			$0!
		}
	}
}

extension AWSS3TransferUtility {
	func uploadFile(_ fileURL: URL, key: String, contentType: String, expression: AWSS3TransferUtilityUploadExpression?) -> Promise<AWSS3TransferUtilityUploadTask> {
		return wrap {
			self.uploadFile(fileURL, key: key, contentType: contentType, expression: expression, completionHandler: $0)
		}
	}

	func download(to fileURL: URL, key: String, expression: AWSS3TransferUtilityDownloadExpression) -> Promise<Void> {
		return Promise<Void> { fulfill, reject in
			self.download(to: fileURL,
			              key: key,
			              expression: expression,
			              completionHandler: { _, _, _, error in
			              	if let error = error {
			              		reject(error)
			              	} else {
			              		fulfill(())
			              	}
			              })
		}
	}
}
