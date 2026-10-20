//
//  BoxJSON.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// A file, folder or web link, as in a listing or in the response of a request on the item.
struct BoxEntry: Decodable, Sendable {
	let type: String
	let id: String
	let name: String?
	let size: Int64?
	let modifiedAt: String?

	private enum CodingKeys: String, CodingKey {
		case type
		case id
		case name
		case size
		case modifiedAt = "modified_at"
	}

	/// The type of a file or a folder entry, or `nil` for any other entry, e.g., a web link.
	var itemType: CloudItemType? {
		switch type {
		case "file":
			return .file
		case "folder":
			return .folder
		default:
			return nil
		}
	}
}

struct BoxItems: Decodable, Sendable {
	let entries: [BoxEntry]?
	let nextMarker: String?

	private enum CodingKeys: String, CodingKey {
		case entries
		case nextMarker = "next_marker"
	}
}

/// The response of an upload, which lists the uploaded file.
struct BoxFiles: Decodable, Sendable {
	let entries: [BoxEntry]?
}

struct BoxUploadSession: Decodable, Sendable {
	struct Endpoints: Decodable, Sendable {
		let uploadPart: String?
		let commit: String?

		// swiftlint:disable:next nesting
		private enum CodingKeys: String, CodingKey {
			case uploadPart = "upload_part"
			case commit
		}
	}

	let partSize: Int64?
	let sessionEndpoints: Endpoints?

	private enum CodingKeys: String, CodingKey {
		case partSize = "part_size"
		case sessionEndpoints = "session_endpoints"
	}
}

/// An uploaded part, which the commit lists as Box returned it.
struct BoxPart: Codable, Sendable, Equatable {
	let partID: String?
	let offset: Int64?
	let size: Int64?
	let sha1: String?

	private enum CodingKeys: String, CodingKey {
		case partID = "part_id"
		case offset
		case size
		case sha1
	}
}

struct BoxUploadedPart: Decodable, Sendable {
	let part: BoxPart?
}

struct BoxUser: Decodable, Sendable {
	let id: String
	let name: String?
}

struct BoxTokenResponse: Decodable, Sendable {
	let accessToken: String
	let refreshToken: String?
	let expiresIn: Int64?

	private enum CodingKeys: String, CodingKey {
		case accessToken = "access_token"
		case refreshToken = "refresh_token"
		case expiresIn = "expires_in"
	}
}

/// The error body of the API, with `code` and `message`, or of the token endpoint, with `error` and `error_description`.
struct BoxErrorResponse: Decodable, Sendable {
	let code: String?
	let message: String?
	let error: String?
	let errorDescription: String?

	private enum CodingKeys: String, CodingKey {
		case code
		case message
		case error
		case errorDescription = "error_description"
	}
}

struct BoxParentReference: Encodable, Sendable {
	let id: String
}

/// The body of a request that names an item and optionally moves it, and the `attributes` part of an upload.
struct BoxItemRequest: Encodable, Sendable {
	let name: String
	let parent: BoxParentReference?
}

struct BoxUploadSessionRequest: Encodable, Sendable {
	let folderID: String?
	let fileSize: Int64
	let fileName: String?

	private enum CodingKeys: String, CodingKey {
		case folderID = "folder_id"
		case fileSize = "file_size"
		case fileName = "file_name"
	}
}

struct BoxCommitRequest: Encodable, Sendable {
	let parts: [BoxPart]
}

enum BoxJSON {
	private static let dateFormatters = ["yyyy-MM-dd'T'HH:mm:ssxxx", "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"].map { dateFormat in
		let formatter = DateFormatter()
		formatter.dateFormat = dateFormat
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.calendar = Calendar(identifier: .iso8601)
		return formatter
	}

	/// Parses a date-time as the Box SDK did, so that a file's date stays equal to the one its earlier download recorded.
	static func date(fromBoxDateTime string: String) -> Date? {
		return dateFormatters.lazy.compactMap { $0.date(from: string) }.first
	}

	static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
		do {
			return try JSONDecoder().decode(type, from: body)
		} catch {
			throw BoxError.unexpectedContent
		}
	}
}

/// The token that the Box SDK stored as JSON, with `access_token`, `refresh_token`, `expires_in` and more. It has no issue time, so its expiry is unknown.
enum BoxLegacyToken {
	private struct StoredToken: Decodable {
		let accessToken: String?
		let refreshToken: String?

		// swiftlint:disable:next nesting
		private enum CodingKeys: String, CodingKey {
			case accessToken = "access_token"
			case refreshToken = "refresh_token"
		}
	}

	/// - Throws: `BoxError.unexpectedContent` if the data has no access token.
	static func decode(_ data: Data) throws -> OAuthToken {
		let storedToken = try BoxJSON.decode(StoredToken.self, from: data)
		guard let accessToken = storedToken.accessToken else {
			throw BoxError.unexpectedContent
		}
		return OAuthToken(accessToken: accessToken, refreshToken: storedToken.refreshToken, expiresAt: nil)
	}
}
