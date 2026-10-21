//
//  GoogleDriveJSON.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AppAuthCore
import Foundation

/// A file or folder with the fields that its request asked for, so that every field may be missing.
struct GoogleDriveFile: Decodable, Sendable {
	struct ShortcutDetails: Decodable, Sendable {
		let targetId: String?
		let targetMimeType: String?
	}

	let id: String?
	let name: String?
	let mimeType: String?
	let modifiedTime: String?
	/// The size in bytes, an int64 in a string.
	let size: String?
	let shortcutDetails: ShortcutDetails?

	var cloudItemType: CloudItemType {
		return mimeType.map(GoogleDriveJSON.cloudItemType(ofMimeType:)) ?? .unknown
	}

	var lastModifiedDate: Date? {
		return modifiedTime.flatMap(GoogleDriveDate.date(fromRFC3339:))
	}

	var sizeValue: Int? {
		get throws {
			guard let size else {
				return nil
			}
			guard let sizeValue = Int(size) else {
				throw GoogleDriveError.unexpectedContent
			}
			return sizeValue
		}
	}
}

struct GoogleDriveFileList: Decodable, Sendable {
	let files: [GoogleDriveFile]?
	let nextPageToken: String?
}

struct GoogleDriveAbout: Decodable, Sendable {
	struct User: Decodable, Sendable {
		let emailAddress: String?
	}

	let user: User?
}

struct GoogleDriveErrorResponse: Decodable, Sendable {
	struct Body: Decodable, Sendable {
		let message: String?
		let errors: [Item]?
	}

	struct Item: Decodable, Sendable {
		let reason: String?
	}

	let error: Body?
}

/// The metadata of a request that creates, renames or moves an item, or of an upload.
struct GoogleDriveFileMetadata: Encodable, Sendable {
	let name: String?
	let parents: [String]?
	let mimeType: String?
}

enum GoogleDriveJSON {
	static let folderMimeType = "application/vnd.google-apps.folder"

	static func cloudItemType(ofMimeType mimeType: String) -> CloudItemType {
		switch mimeType {
		case folderMimeType:
			return .folder
		case "application/vnd.google-apps.shortcut":
			return .symlink
		default:
			return .file
		}
	}

	static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
		do {
			return try JSONDecoder().decode(type, from: body)
		} catch {
			throw GoogleDriveError.unexpectedContent
		}
	}
}

/// Parses `modifiedTime` exactly as `GTLRDateTime` of the Google API client did, so that a file's date stays equal to the one its earlier download recorded. `ISO8601DateFormatter` rounds the milliseconds differently.
enum GoogleDriveDate {
	private static let calendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "Universal") ?? .gmt
		return calendar
	}()

	/// Reads `yyyy-MM-dd`, a `T`, `t` or space, `HH:mm:` and the seconds as a double, then an optional `±hh:mm` offset. The milliseconds are rounded and added after the date is built from its components.
	static func date(fromRFC3339 string: String) -> Date? {
		let scanner = Scanner(string: string)
		scanner.charactersToBeSkipped = nil
		guard let year = scanner.scanInt(), scanner.scanCharacters(from: CharacterSet(charactersIn: "-")) != nil,
		      let month = scanner.scanInt(), scanner.scanCharacters(from: CharacterSet(charactersIn: "-")) != nil,
		      let day = scanner.scanInt(), scanner.scanCharacters(from: CharacterSet(charactersIn: "Tt ")) != nil,
		      let hour = scanner.scanInt(), scanner.scanCharacters(from: CharacterSet(charactersIn: ":")) != nil,
		      let minute = scanner.scanInt(), scanner.scanCharacters(from: CharacterSet(charactersIn: ":")) != nil,
		      let seconds = scanner.scanDouble() else {
			return nil
		}
		// Converting seconds out of `Int`'s range would trap.
		guard let wholeSeconds = Int(exactly: seconds.rounded(.towardZero)) else {
			return nil
		}
		let milliseconds = Int(((seconds - Double(wholeSeconds)) * 1000).rounded(.toNearestOrAwayFromZero))
		var components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: wholeSeconds)
		if let sign = scanner.scanCharacters(from: CharacterSet(charactersIn: "+-zZ")), sign == "+" || sign == "-", let offsetHour = scanner.scanInt(), scanner.scanCharacters(from: CharacterSet(charactersIn: ":")) != nil, let offsetMinute = scanner.scanInt() {
			// The arithmetic would trap on an overflow, so such a date is rejected.
			let (hourMinutes, hourOverflow) = offsetHour.multipliedReportingOverflow(by: 60)
			let (offsetMinutes, minuteOverflow) = hourMinutes.addingReportingOverflow(offsetMinute)
			let (correctionSeconds, secondOverflow) = offsetMinutes.multipliedReportingOverflow(by: sign == "-" ? 60 : -60)
			guard !hourOverflow, !minuteOverflow, !secondOverflow, let scannedDate = calendar.date(from: components) else {
				return nil
			}
			components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: scannedDate.addingTimeInterval(TimeInterval(correctionSeconds)))
		}
		guard let date = calendar.date(from: components) else {
			return nil
		}
		return milliseconds > 0 ? date.addingTimeInterval(TimeInterval(milliseconds) / 1000) : date
	}
}

/// The login that GTMAppAuth stored: an archived `GTMAppAuthFetcherAuthorization` with the `OIDAuthState` and the account's email.
enum GoogleDriveLegacyToken {
	/**
	 - Throws: `CloudProviderError.unauthorized` if the login has an authorization error, or no access token or refresh token, and `GoogleDriveError.unexpectedContent` if the data isn't such an archive.
	 */
	static func decode(_ data: Data) throws -> OAuthToken {
		let session: GoogleDriveLegacyAuthSession?
		do {
			let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
			unarchiver.requiresSecureCoding = true
			unarchiver.setClass(GoogleDriveLegacyAuthSession.self, forClassName: "GTMAppAuthFetcherAuthorization")
			session = unarchiver.decodeObject(of: GoogleDriveLegacyAuthSession.self, forKey: NSKeyedArchiveRootObjectKey)
		} catch {
			throw GoogleDriveError.unexpectedContent
		}
		guard let session else {
			throw GoogleDriveError.unexpectedContent
		}
		guard let authState = session.authState, authState.authorizationError == nil, let refreshToken = authState.refreshToken else {
			throw CloudProviderError.unauthorized
		}
		let (accessToken, expiresAt) = if let tokenResponse = authState.lastTokenResponse {
			(tokenResponse.accessToken, tokenResponse.accessTokenExpirationDate)
		} else {
			(authState.lastAuthorizationResponse.accessToken, authState.lastAuthorizationResponse.accessTokenExpirationDate)
		}
		guard let accessToken else {
			throw CloudProviderError.unauthorized
		}
		return OAuthToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, username: session.userEmail)
	}
}

/// Reads the keys of GTMAppAuth's `GTMAppAuthFetcherAuthorization` that the library needs.
@objc(CryptomatorGoogleDriveLegacyAuthSession)
private final class GoogleDriveLegacyAuthSession: NSObject, NSSecureCoding {
	private static let authStateKey = "authState"
	private static let userEmailKey = "userEmail"

	static var supportsSecureCoding: Bool {
		return true
	}

	let authState: OIDAuthState?
	let userEmail: String?

	init?(coder: NSCoder) {
		self.authState = coder.decodeObject(of: OIDAuthState.self, forKey: GoogleDriveLegacyAuthSession.authStateKey)
		self.userEmail = coder.decodeObject(of: NSString.self, forKey: GoogleDriveLegacyAuthSession.userEmailKey) as String?
		super.init()
	}

	func encode(with coder: NSCoder) {
		coder.encode(authState, forKey: GoogleDriveLegacyAuthSession.authStateKey)
		coder.encode(userEmail, forKey: GoogleDriveLegacyAuthSession.userEmailKey)
	}
}
