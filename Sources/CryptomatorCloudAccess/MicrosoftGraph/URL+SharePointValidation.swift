//
//  URL+SharePointValidation.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.03.25.
//  Copyright © 2025 Skymatic GmbH. All rights reserved.
//

import Foundation

public extension URL {
	func validateForSharePoint() throws -> URL {
		let urlString = absoluteString
		guard !urlString.isEmpty else {
			throw SharePointURLValidationError.emptyURL
		}
		// Regex pattern breakdown:
		// ^https:\/\/                    => URL must start with "https://"
		// [a-zA-Z0-9-]+\.sharepoint\.com => Domain must include the subdomain and ".sharepoint.com"
		// \/(sites|teams)\/              => Path must contain either "/sites/" or "/teams/"
		// [^\/]+                         => Site name must contain one or more characters that are not a slash
		// $                              => End of string
		let pattern = #"^https:\/\/[a-zA-Z0-9-]+\.sharepoint\.com\/(sites|teams)\/[^\/]+$"#
		let regex = try NSRegularExpression(pattern: pattern)
		let range = NSRange(urlString.startIndex..., in: urlString)
		guard regex.firstMatch(in: urlString, range: range) != nil, let url = URL(string: urlString) else {
			throw SharePointURLValidationError.invalidURL
		}
		return self
	}
}

public enum SharePointURLValidationError: Error {
	case emptyURL
	case invalidURL
}
