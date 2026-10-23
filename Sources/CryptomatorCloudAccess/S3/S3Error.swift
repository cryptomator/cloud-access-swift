//
//  S3Error.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 An error response of S3, either with a non-2xx status or as an `<Error>` document in a 2xx response.

 It keeps the status, code, message, argument name, reason and bucket region. An error body can echo `StringToSign`, `CanonicalRequest`, `SignatureProvided` and `AWSAccessKeyId`, which are never kept.
 */
struct S3Error: Error, Equatable, CustomStringConvertible {
	let statusCode: Int
	let code: String?
	let message: String?
	let argumentName: String?
	let reason: String?

	/// The bucket's region if the response names a valid one, as S3 does in an error to a request in another region.
	let bucketRegion: String?

	init(statusCode: Int, code: String? = nil, message: String? = nil, argumentName: String? = nil, reason: String? = nil, bucketRegion: String? = nil) {
		self.statusCode = statusCode
		self.code = code
		self.message = message
		self.argumentName = argumentName
		self.reason = reason
		self.bucketRegion = bucketRegion
	}

	/// A body that isn't an `<Error>` document yields an error with only the status and the header's bucket region, if that is a valid region.
	init(statusCode: Int, body: Data, bucketRegionHeader: String? = nil) {
		self = S3Error(errorDocument: body, statusCode: statusCode, bucketRegionHeader: bucketRegionHeader) ?? S3Error(statusCode: statusCode, bucketRegion: bucketRegionHeader.flatMap(S3Error.validRegion))
	}

	/**
	 Returns the error of an `<Error>` document, or `nil` if the body is no well-formed `<Error>` document.

	 - Parameter bucketRegionHeader: The `x-amz-bucket-region` header of the response, which is the bucket region if it is a valid region. Otherwise the document's `<Region>` is, if it is one.
	 */
	init?(errorDocument body: Data, statusCode: Int, bucketRegionHeader: String? = nil) {
		guard S3XMLElement.rootName(of: body) == "Error", let root = S3XMLElement.parse(body) else {
			return nil
		}
		let bucketRegion = bucketRegionHeader.flatMap(S3Error.validRegion) ?? root.text(of: "Region").flatMap(S3Error.validRegion)
		self.init(statusCode: statusCode, code: root.text(of: "Code"), message: root.text(of: "Message"), argumentName: root.text(of: "ArgumentName"), reason: root.text(of: "Reason"), bucketRegion: bucketRegion)
	}

	/// Whether the request went to a region in which the bucket isn't: a 301, or an error code that botocore's region redirector reads as one.
	var isWrongRegion: Bool {
		return statusCode == 301 || code.map(["PermanentRedirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException"].contains) ?? false
	}

	private static func validRegion(_ region: String) -> String? {
		return S3Signer.isValidRegion(region) ? region : nil
	}

	var description: String {
		let fields = [("code", code), ("message", message), ("argumentName", argumentName), ("reason", reason), ("bucketRegion", bucketRegion)].compactMap { name, value in
			value.map { "\(name): \($0)" }
		}
		return "S3Error(\((["statusCode: \(statusCode)"] + fields).joined(separator: ", ")))"
	}
}

enum S3ResponseError: Error {
	/// A 2xx response lacks the result that its operation returns, e.g., because S3 cut a long-running copy short, or carries an `<Error>` document that can't be read.
	case unparseableResult
}
