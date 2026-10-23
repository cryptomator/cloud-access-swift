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

	init(client: S3Client, concurrencyLimit: Int = 4, maxPartSize: Int = S3Client.maxPartSize) {
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

	/// Copies the objects with at most `concurrencyLimit` of them at a time.
	func copy(_ requests: [S3CopyRequest]) async throws {
		_ = try await mapConcurrently(requests, limit: concurrencyLimit) { request in
			try await self.copy(request)
		}
	}

	private func regularCopy(_ request: S3CopyRequest) async throws {
		CloudAccessDDLogDebug("S3CopyTaskUtility: regularCopy(\(request)) called")
		try await client.copyObject(sourceKey: request.sourceKey, targetKey: request.targetKey)
		CloudAccessDDLogDebug("S3CopyTaskUtility: regularCopy(\(request)) finished")
	}

	private func multipartCopy(_ request: S3CopyRequest) async throws {
		CloudAccessDDLogDebug("S3CopyTaskUtility: multipartCopy(\(request)) called")
		let parts = constructParts(itemSize: request.itemSize)
		try await client.multipartUpload(key: request.targetKey, contentType: nil) { uploadID in
			try await mapConcurrently(parts, limit: concurrencyLimit) { part in
				try await (partNumber: part.partNumber, eTag: self.copyPart(part, of: request, uploadID: uploadID))
			}
		}
		CloudAccessDDLogDebug("S3CopyTaskUtility: multipartCopy(\(request)) finished")
	}

	private func copyPart(_ part: S3CopyPart, of request: S3CopyRequest, uploadID: String) async throws -> String {
		CloudAccessDDLogDebug("S3CopyTaskUtility: copyPart(\(part.partNumber)) called")
		let eTag = try await client.uploadPartCopy(sourceKey: request.sourceKey, range: part.range, key: request.targetKey, uploadID: uploadID, partNumber: part.partNumber)
		CloudAccessDDLogDebug("S3CopyTaskUtility: copyPart(\(part.partNumber)) finished")
		return eTag
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
}

struct S3CopyRequest {
	let sourceKey: String
	let targetKey: String
	let itemSize: Int
}
