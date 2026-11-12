//
//  IntegrationTestSecrets.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 20.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessCore
import Foundation

enum IntegrationTestSecretsError: Error, Equatable {
	/// The line holds something other than `export KEY=value`. It carries the line's number, because the line itself can hold a secret.
	case unsupportedLine(Int)
	case missingValue(String)
	case invalidURL(String)
}

/// The secrets in `.integration-test-secrets.sh` in the repository's root, read when a test first needs one. The tests run on the simulator of the machine that built them, so they find the file through the path of this source file.
enum IntegrationTestSecrets {
	static var boxClientId: String {
		get throws { try value(for: "BOX_CLIENT_ID") }
	}

	static var boxClientSecret: String {
		get throws { try value(for: "BOX_CLIENT_SECRET") }
	}

	static var boxEnterpriseId: String {
		get throws { try value(for: "BOX_ENTERPRISE_ID") }
	}

	static var dropboxAppKey: String {
		get throws { try value(for: "DROPBOX_APP_KEY") }
	}

	static var dropboxRefreshToken: String {
		get throws { try value(for: "DROPBOX_REFRESH_TOKEN") }
	}

	static var googleDriveClientId: String {
		get throws { try value(for: "GOOGLE_DRIVE_CLIENT_ID") }
	}

	static var googleDriveRefreshToken: String {
		get throws { try value(for: "GOOGLE_DRIVE_REFRESH_TOKEN") }
	}

	static var microsoftGraphClientId: String {
		get throws { try value(for: "MICROSOFT_GRAPH_CLIENT_ID") }
	}

	static var microsoftGraphRedirectUri: String {
		get throws { try "\(value(for: "MICROSOFT_GRAPH_REDIRECT_URI_SCHEME"))://auth" }
	}

	static var microsoftGraphRefreshToken: String {
		get throws { try value(for: "MICROSOFT_GRAPH_REFRESH_TOKEN") }
	}

	static var pCloudAccessToken: String {
		get throws { try value(for: "PCLOUD_ACCESS_TOKEN") }
	}

	static var pCloudHTTPAPIHostName: String {
		get throws { try value(for: "PCLOUD_HTTP_API_HOST_NAME") }
	}

	static var s3Credential: S3Credential {
		get throws {
			return try S3Credential(accessKey: value(for: "S3_ACCESS_KEY"), secretKey: value(for: "S3_SECRET_KEY"), url: url(for: "S3_URL"), bucket: value(for: "S3_BUCKET"), region: value(for: "S3_REGION"))
		}
	}

	static var webDAVCredential: WebDAVCredential {
		get throws {
			return try WebDAVCredential(baseURL: url(for: "WEBDAV_BASE_URL"), username: value(for: "WEBDAV_USERNAME"), password: value(for: "WEBDAV_PASSWORD"), allowedCertificate: nil)
		}
	}

	private static let values = Result {
		let fileURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".integration-test-secrets.sh")
		return try parse(String(contentsOf: fileURL, encoding: .utf8))
	}

	/**
	 Reads the `export KEY=value` lines of a shell script without running it. Empty lines and lines starting with `#` are skipped.

	 A value is unquoted, single-quoted or double-quoted and holds nothing that a shell would expand, unescape or split, so that it reads the same here as in a shell. An unquoted value therefore holds only letters, digits and `_./:+=@%,-`.

	 - Throws: `IntegrationTestSecretsError.unsupportedLine` for any other line.
	 */
	static func parse(_ script: String) throws -> [String: String] {
		var values = [String: String]()
		let exportLine = #/
			export\ (?<key> [A-Za-z_][A-Za-z0-9_]*)=
			(?:
				'(?<singleQuoted> [^']*)'
				| "(?<doubleQuoted> [^"$`\\]*)"
				| (?<unquoted> [A-Za-z0-9_.\/:+=@%,\-]*)
			)
		/#
		for (index, line) in script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
			let line = line.trimmingCharacters(in: .whitespaces)
			if line.isEmpty || line.hasPrefix("#") {
				continue
			}
			guard let match = line.wholeMatch(of: exportLine), let value = match.singleQuoted ?? match.doubleQuoted ?? match.unquoted else {
				throw IntegrationTestSecretsError.unsupportedLine(index + 1)
			}
			values[String(match.key)] = String(value)
		}
		return values
	}

	private static func value(for key: String) throws -> String {
		guard let value = try values.get()[key] else {
			throw IntegrationTestSecretsError.missingValue(key)
		}
		return value
	}

	private static func url(for key: String) throws -> URL {
		guard let url = try URL(string: value(for: key)) else {
			throw IntegrationTestSecretsError.invalidURL(key)
		}
		return url
	}
}
