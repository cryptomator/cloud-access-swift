//
//  DropboxJSON.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// A file or folder. Only a response that Dropbox declares as `Metadata` tags it, e.g., an entry of a listing. An upload or a download returns a file without a tag.
struct DropboxMetadata: Decodable, Sendable {
	let tag: String?
	let name: String
	let size: Int64?
	let serverModified: String?

	private enum CodingKeys: String, CodingKey {
		case tag = ".tag"
		case name
		case size
		case serverModified = "server_modified"
	}

	/// - Throws: `DropboxError.unexpectedContent` if `server_modified` is missing or doesn't parse.
	var lastModifiedDate: Date {
		get throws {
			guard let serverModified, let date = DropboxDate.date(from: serverModified) else {
				throw DropboxError.unexpectedContent
			}
			return date
		}
	}

	/**
	 Returns the type that the tag names, or `untaggedType` for an entry without a tag.

	 - Parameter untaggedType: The type of the item that the route returns without a tag, or `nil` if the route tags every item.
	 - Throws: `DropboxError.unexpectedContent` for any other tag, e.g., `deleted`, and for an entry without a tag if `untaggedType` is `nil`.
	 */
	func cloudItemType(untaggedAs untaggedType: CloudItemType?) throws -> CloudItemType {
		switch tag {
		case "folder":
			return .folder
		case "file":
			return .file
		case nil:
			guard let untaggedType else {
				throw DropboxError.unexpectedContent
			}
			return untaggedType
		default:
			throw DropboxError.unexpectedContent
		}
	}
}

struct DropboxListFolderResult: Decodable, Sendable {
	let entries: [DropboxMetadata]
	let cursor: String
	let hasMore: Bool

	private enum CodingKeys: String, CodingKey {
		case entries
		case cursor
		case hasMore = "has_more"
	}
}

struct DropboxUploadSessionStart: Decodable, Sendable {
	let sessionID: String

	private enum CodingKeys: String, CodingKey {
		case sessionID = "session_id"
	}
}

struct DropboxAccount: Decodable, Sendable {
	let email: String?
}

/// The `uid` of a code exchange's response, which `OAuthTokenResponse` doesn't read.
struct DropboxAccountID: Decodable, Sendable {
	let uid: String?
}

/// The details of an error body that the library reads.
struct DropboxErrorDetails: Decodable, Sendable {
	/// The offset that an upload session expects, of an `incorrect_offset`.
	let correctOffset: Int64?
	/// The seconds to wait, of a 429.
	let retryAfter: Double?

	private enum CodingKeys: String, CodingKey {
		case correctOffset = "correct_offset"
		case retryAfter = "retry_after"
	}
}

/// The error body of an RPC or content route, e.g., `{"error_summary": "path/not_found/..", "error": {...}}`.
struct DropboxErrorResponse: Decodable, Sendable {
	private static let maxPlainTextSummaryLength = 200

	let errorSummary: String?
	let error: DropboxErrorDetails?

	private enum CodingKeys: String, CodingKey {
		case errorSummary = "error_summary"
		case error
	}

	static func decode(from body: Data?) -> DropboxErrorResponse? {
		return body.flatMap { try? JSONDecoder().decode(DropboxErrorResponse.self, from: $0) }
	}

	/// Returns the `error_summary` of the body, or the first line of the plain text with which Dropbox answers a malformed request with 400.
	static func summary(of body: Data?, statusCode: Int) -> String? {
		if let errorSummary = decode(from: body)?.errorSummary {
			return errorSummary
		}
		guard statusCode == 400, let body, let text = String(data: body, encoding: .utf8), let firstLine = text.split(whereSeparator: \.isNewline).first else {
			return nil
		}
		return String(firstLine.prefix(maxPlainTextSummaryLength))
	}

	/// Splits an `error_summary` into its tags, e.g., `path/not_found/..` into `["path", "not_found"]`.
	static func tags(of summary: String?) -> [String] {
		return (summary ?? "").split(separator: "/").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
	}
}

enum DropboxJSON {
	static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
		do {
			return try JSONDecoder().decode(type, from: body)
		} catch {
			throw DropboxError.unexpectedContent
		}
	}
}

/// Parses `server_modified` as SwiftyDropbox did, so that a file's date stays equal to the one its earlier download recorded.
enum DropboxDate {
	private static let formatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.timeZone = TimeZone(identifier: "UTC")
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
		return formatter
	}()

	static func date(from string: String) -> Date? {
		return formatter.date(from: string)
	}
}

/// Encodes the argument of a route, in the snake case of the API.
enum DropboxArgument {
	static func json(_ value: some Encodable) throws -> Data {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		encoder.outputFormatting = .sortedKeys
		return try encoder.encode(value)
	}

	/// Returns the argument as JSON for the `Dropbox-API-Arg` header, with every UTF-16 code unit from 0x7F up written as `\uXXXX`, so that the header is printable ASCII.
	static func header(_ value: some Encodable) throws -> String {
		guard let json = try String(data: json(value), encoding: .utf8) else {
			throw DropboxError.unexpectedContent
		}
		return json.utf16.map { codeUnit in
			if codeUnit < 0x7F, let scalar = Unicode.Scalar(codeUnit) {
				return String(Character(scalar))
			}
			return String(format: "\\u%04x", codeUnit)
		}.joined()
	}
}

/// The logins that the Dropbox SDKs stored: SwiftyDropbox's JSON, the ObjC SDK's archive, or the plain access token of older versions of the ObjC SDK.
enum DropboxLegacyToken {
	private struct SwiftyDropboxAccessToken: Decodable {
		let accessToken: String
		let refreshToken: String?
		/// Seconds since 1970.
		let tokenExpirationTimestamp: TimeInterval?
	}

	/**
	 A token without a refresh token or an expiry is long-lived: it is never refreshed, and Dropbox's rejection ends the login.

	 - Throws: `CloudProviderError.unauthorized` for data that is empty or no UTF-8 text.
	 */
	static func decode(_ data: Data) throws -> OAuthToken {
		if let token = try? JSONDecoder().decode(SwiftyDropboxAccessToken.self, from: data) {
			return oauthToken(accessToken: token.accessToken, refreshToken: token.refreshToken, expiresAt: token.tokenExpirationTimestamp)
		} else if let token = LegacyDropboxAccessToken.decode(from: data) {
			// The ObjC SDK archived a long-lived token with an expiry of 0.
			return oauthToken(accessToken: token.accessToken, refreshToken: token.refreshToken, expiresAt: token.tokenExpirationTimestamp > 0 ? token.tokenExpirationTimestamp : nil)
		}
		guard !data.isEmpty, let accessToken = String(data: data, encoding: .utf8) else {
			throw CloudProviderError.unauthorized
		}
		return OAuthToken(accessToken: accessToken, refreshToken: nil, expiresAt: nil)
	}

	private static func oauthToken(accessToken: String, refreshToken: String?, expiresAt: TimeInterval?) -> OAuthToken {
		guard let refreshToken, let expiresAt else {
			return OAuthToken(accessToken: accessToken, refreshToken: nil, expiresAt: nil)
		}
		return OAuthToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: Date(timeIntervalSince1970: expiresAt))
	}
}

/// Decodes the `DBAccessToken` that the ObjC Dropbox SDK archived with `NSKeyedArchiver`.
@objc(CryptomatorLegacyDropboxAccessToken)
private final class LegacyDropboxAccessToken: NSObject, NSSecureCoding {
	static let supportsSecureCoding = true

	let accessToken: String
	let refreshToken: String?
	/// Seconds since 1970 at which a short-lived access token expires, or 0 for a long-lived one.
	let tokenExpirationTimestamp: TimeInterval

	init?(coder: NSCoder) {
		guard let accessToken = coder.decodeObject(of: NSString.self, forKey: "accessToken") as String? else {
			return nil
		}
		self.accessToken = accessToken
		self.refreshToken = coder.decodeObject(of: NSString.self, forKey: "refreshToken") as String?
		self.tokenExpirationTimestamp = coder.decodeDouble(forKey: "tokenExpirationTimestamp")
	}

	func encode(with coder: NSCoder) {
		coder.encode(accessToken, forKey: "accessToken")
		coder.encode(refreshToken, forKey: "refreshToken")
		coder.encode(tokenExpirationTimestamp, forKey: "tokenExpirationTimestamp")
	}

	static func decode(from data: Data) -> LegacyDropboxAccessToken? {
		guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
			return nil
		}
		defer {
			unarchiver.finishDecoding()
		}
		unarchiver.setClass(LegacyDropboxAccessToken.self, forClassName: "DBAccessToken")
		return unarchiver.decodeObject(of: LegacyDropboxAccessToken.self, forKey: NSKeyedArchiveRootObjectKey)
	}
}
