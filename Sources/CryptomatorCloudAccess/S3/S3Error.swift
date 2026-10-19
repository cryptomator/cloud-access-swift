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

 It keeps the status, code, message, argument name and reason. An error body can echo `StringToSign`, `CanonicalRequest`, `SignatureProvided` and `AWSAccessKeyId`, which are never kept.
 */
struct S3Error: Error, Equatable, CustomStringConvertible {
	let statusCode: Int
	let code: String?
	let message: String?
	let argumentName: String?
	let reason: String?

	init(statusCode: Int, code: String? = nil, message: String? = nil, argumentName: String? = nil, reason: String? = nil) {
		self.statusCode = statusCode
		self.code = code
		self.message = message
		self.argumentName = argumentName
		self.reason = reason
	}

	/// A body that isn't an `<Error>` document yields an error with only the status.
	init(statusCode: Int, body: Data) {
		self = S3Error(errorDocument: body, statusCode: statusCode) ?? S3Error(statusCode: statusCode)
	}

	/// Returns the error of an `<Error>` document, or `nil` if the body is no well-formed `<Error>` document.
	init?(errorDocument body: Data, statusCode: Int) {
		guard S3XMLElement.rootName(of: body) == "Error", let root = S3XMLElement.parse(body) else {
			return nil
		}
		self.init(statusCode: statusCode, code: root.text(of: "Code"), message: root.text(of: "Message"), argumentName: root.text(of: "ArgumentName"), reason: root.text(of: "Reason"))
	}

	var description: String {
		let fields = [("code", code), ("message", message), ("argumentName", argumentName), ("reason", reason)].compactMap { name, value in
			value.map { "\(name): \($0)" }
		}
		return "S3Error(\((["statusCode: \(statusCode)"] + fields).joined(separator: ", ")))"
	}
}

enum S3ResponseError: Error {
	/// A 2xx response lacks the result that its operation returns, e.g., because S3 cut a long-running copy short, or carries an `<Error>` document that can't be read.
	case unparseableResult
}
